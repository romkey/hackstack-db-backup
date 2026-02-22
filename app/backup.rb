require 'fileutils'
require 'net/http'
require 'json'
require 'time'
require 'optparse'
require 'shellwords'

# Parse command-line options
options = { quiet: false }
OptionParser.new do |opts|
  opts.banner = "Usage: backup_script.rb [options]"

  opts.on("--quiet", "Suppress all output") do
    options[:quiet] = true
  end
end.parse!

# Store as constant for access in methods
OPTIONS = options.freeze

# Environment variables
PARENT_DIR = ENV['PARENT_DIR']
DEST_DIR = ENV['DEST_DIR']
SLACK_WEBHOOK_URL = ENV['SLACK_WEBHOOK_URL']

# Tiered backup retention configuration (defaults to 6 for each tier)
DEFAULT_RETENTION = 6
BACKUP_RETAIN_HOURLY = (ENV['BACKUP_RETAIN_HOURLY'] || DEFAULT_RETENTION).to_i
BACKUP_RETAIN_DAILY = (ENV['BACKUP_RETAIN_DAILY'] || DEFAULT_RETENTION).to_i
BACKUP_RETAIN_WEEKLY = (ENV['BACKUP_RETAIN_WEEKLY'] || DEFAULT_RETENTION).to_i
BACKUP_RETAIN_MONTHLY = (ENV['BACKUP_RETAIN_MONTHLY'] || DEFAULT_RETENTION).to_i
BACKUP_RETAIN_YEARLY = (ENV['BACKUP_RETAIN_YEARLY'] || DEFAULT_RETENTION).to_i

# Validate required environment variables
def validate_environment!
  errors = []
  errors << "PARENT_DIR environment variable is not set" if PARENT_DIR.nil? || PARENT_DIR.empty?
  errors << "DEST_DIR environment variable is not set" if DEST_DIR.nil? || DEST_DIR.empty?
  errors << "PARENT_DIR does not exist: #{PARENT_DIR}" if PARENT_DIR && !File.directory?(PARENT_DIR)

  unless errors.empty?
    errors.each { |e| puts "ERROR: #{e}" }
    exit 1
  end
end

def post_to_slack(message)
  return if SLACK_WEBHOOK_URL.nil? || SLACK_WEBHOOK_URL.empty?

  uri = URI(SLACK_WEBHOOK_URL)
  payload = { text: message }.to_json
  headers = { 'Content-Type' => 'application/json' }

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  request = Net::HTTP::Post.new(uri.path, headers)
  request.body = payload

  response = http.request(request)
  unless response.is_a?(Net::HTTPSuccess)
    puts "Failed to send message to Slack: #{response.body}" unless OPTIONS[:quiet]
  end
rescue StandardError => e
  puts "Exception when posting to Slack: #{e.message}" unless OPTIONS[:quiet]
end

def backup_database(db_url, backup_file)
  command = case db_url
            when /^postgresql:\/\/([^:]*):([^@]*)@([^:]*):(\d+)\/(.*)$/
              user, password, host, port, dbname = $1, $2, $3, $4, $5
              # Use environment variable for password to avoid command injection
              env_prefix = "PGPASSWORD=#{Shellwords.escape(password)}"
              "#{env_prefix} pg_dump -h #{Shellwords.escape(host)} -p #{Shellwords.escape(port)} -U #{Shellwords.escape(user)} -d #{Shellwords.escape(dbname)} -F c -b -v -f #{Shellwords.escape(backup_file)} 2>&1"
            when /^mysql:\/\/([^:]*):([^@]*)@([^:]*):(\d+)\/(.*)$/
              user, password, host, port, dbname = $1, $2, $3, $4, $5
              "mysqldump -h #{Shellwords.escape(host)} -P #{Shellwords.escape(port)} -u #{Shellwords.escape(user)} -p#{Shellwords.escape(password)} #{Shellwords.escape(dbname)} > #{Shellwords.escape(backup_file)} 2>&1"
            when /^sqlite:\/\/(\/.*)$/
              db_path = $1
              "sqlite3 #{Shellwords.escape(db_path)} .dump > #{Shellwords.escape(backup_file)} 2>&1"
            when /^redis:\/\/(?:([^:]*):)?([^@]*)@([^:]*):(\d+)\/(.*)$/
              # Redis URL format: redis://[username]:password@host:port/db
              # or redis://:password@host:port/db (no username)
              _user, password, host, port, dbname = $1, $2, $3, $4, $5
              auth_args = password && !password.empty? ? "-a #{Shellwords.escape(password)}" : ""
              "redis-cli -h #{Shellwords.escape(host)} -p #{Shellwords.escape(port)} #{auth_args} -n #{Shellwords.escape(dbname)} --rdb #{Shellwords.escape(backup_file)} 2>&1"
            else
              error_message = "Unsupported database URL format: #{db_url}"
              puts error_message unless OPTIONS[:quiet]
              post_to_slack(error_message)
              return false
            end

  output = `#{command}`
  if $?.exitstatus != 0
    error_message = "Error backing up database: #{db_url}\nOutput: #{output}"
    puts error_message unless OPTIONS[:quiet]
    post_to_slack(error_message)
    return false
  else
    compress_file(backup_file)
    return true
  end
end

def compress_file(file)
  compressed_file = "#{file}.bz2"
  system("bzip2 -c #{Shellwords.escape(file)} > #{Shellwords.escape(compressed_file)}")
  if $?.exitstatus == 0
    File.delete(file)
    puts "Compressed and deleted original backup file: #{file}" unless OPTIONS[:quiet]
    true
  else
    error_message = "Error compressing file: #{file}"
    puts error_message unless OPTIONS[:quiet]
    post_to_slack(error_message)
    false
  end
end

def parse_database_urls(env_file)
  db_urls = []
  File.foreach(env_file) do |line|
    if line =~ /^BACKUP_DATABASE_URLS=(.*)$/
      urls = $1.strip
      # Remove enclosing quotes (single or double)
      urls = urls[1..-2] if (urls.start_with?('"') && urls.end_with?('"')) ||
                            (urls.start_with?("'") && urls.end_with?("'"))
      # Split and clean up individual URLs
      db_urls = urls.split(',').map { |url| url.strip.gsub(/["']/, '') }
      break
    end
  end
  db_urls
end

def process_directory(dir)
  env_file = File.join(dir, ".env")
  return [] unless File.exist?(env_file)

  db_urls = parse_database_urls(env_file)
  pids = []

  db_urls.each do |db_url|
    timestamp = Time.now.strftime("%Y%m%d%H%M%S")
    backup_subdir = File.join(DEST_DIR, File.basename(dir))
    FileUtils.mkdir_p(backup_subdir)

    backup_filename = case db_url
                      when /^postgresql:\/\/([^:]*):([^@]*)@([^:]*):(\d+)\/(.*)$/
                        dbname = $5
                        "backup-#{dbname}-#{timestamp}.sql"
                      when /^mysql:\/\/([^:]*):([^@]*)@([^:]*):(\d+)\/(.*)$/
                        dbname = $5
                        "backup-#{dbname}-#{timestamp}.sql"
                      when /^sqlite:\/\/(\/.*)$/
                        db_path = $1
                        dbname = File.basename(db_path, ".*")
                        "backup-#{dbname}-#{timestamp}.sql"
                      when /^redis:\/\/(?:[^:]*:)?[^@]*@[^:]*:\d+\/(.*)$/
                        dbname = $1
                        "backup-#{dbname}-#{timestamp}.rdb"
                      else
                        next
                      end

    backup_file = File.join(backup_subdir, backup_filename)
    puts "Backing up database to #{backup_file}" unless OPTIONS[:quiet]

    # Fork to run backups in parallel, but don't detach so we can wait
    pid = fork do
      success = backup_database(db_url, backup_file)
      exit(success ? 0 : 1)
    end
    pids << pid
  end

  pids
end

def parse_backup_timestamp(filename)
  # Extract timestamp from filename format: backup-{dbname}-{YYYYMMDDHHMMSS}.{ext}.bz2
  if filename =~ /backup-.*-(\d{14})\.(sql|rdb)(\.bz2)?$/
    Time.strptime($1, "%Y%m%d%H%M%S")
  else
    nil
  end
end

def extract_dbname(filename)
  # Extract database name from filename: backup-{dbname}-{timestamp}.{ext}.bz2
  if filename =~ /backup-(.+)-\d{14}\.(sql|rdb)(\.bz2)?$/
    $1
  else
    nil
  end
end

def categorize_backups(backup_files)
  # Group backups by their time bucket, keeping the most recent backup for each bucket
  hourly = {}   # key: "YYYY-MM-DD-HH"
  daily = {}    # key: "YYYY-MM-DD"
  weekly = {}   # key: "YYYY-WW" (ISO week)
  monthly = {}  # key: "YYYY-MM"
  yearly = {}   # key: "YYYY"

  # Sort by timestamp descending (newest first)
  sorted_files = backup_files.map { |f| [f, parse_backup_timestamp(File.basename(f))] }
                             .reject { |_, ts| ts.nil? }
                             .sort_by { |_, ts| -ts.to_i }

  sorted_files.each do |file, timestamp|
    hour_key = timestamp.strftime("%Y-%m-%d-%H")
    day_key = timestamp.strftime("%Y-%m-%d")
    week_key = timestamp.strftime("%G-%V")  # ISO week
    month_key = timestamp.strftime("%Y-%m")
    year_key = timestamp.strftime("%Y")

    # Keep the newest backup for each time bucket
    hourly[hour_key] ||= file
    daily[day_key] ||= file
    weekly[week_key] ||= file
    monthly[month_key] ||= file
    yearly[year_key] ||= file
  end

  {
    hourly: hourly.values.take(BACKUP_RETAIN_HOURLY),
    daily: daily.values.take(BACKUP_RETAIN_DAILY),
    weekly: weekly.values.take(BACKUP_RETAIN_WEEKLY),
    monthly: monthly.values.take(BACKUP_RETAIN_MONTHLY),
    yearly: yearly.values.take(BACKUP_RETAIN_YEARLY)
  }
end

def cleanup_old_backups(dir)
  backup_subdir = File.join(DEST_DIR, File.basename(dir))
  return unless File.directory?(backup_subdir)

  # Group backup files by database name
  all_files = Dir.glob(File.join(backup_subdir, 'backup-*.{sql,rdb}.bz2')) +
              Dir.glob(File.join(backup_subdir, 'backup-*.{sql,rdb}'))

  files_by_db = all_files.group_by { |f| extract_dbname(File.basename(f)) }
                         .reject { |k, _| k.nil? }

  files_by_db.each do |dbname, files|
    # Categorize backups into retention tiers
    retained = categorize_backups(files)

    # Collect all files to keep (union of all tiers)
    files_to_keep = (retained[:hourly] + retained[:daily] + retained[:weekly] +
                     retained[:monthly] + retained[:yearly]).uniq

    # Delete files not in any retention tier
    files.each do |file|
      unless files_to_keep.include?(file)
        File.delete(file)
        puts "Deleted old backup file: #{file}" unless OPTIONS[:quiet]
      end
    end

    unless OPTIONS[:quiet]
      puts "Retention for #{dbname}: #{retained[:hourly].size} hourly, " \
           "#{retained[:daily].size} daily, #{retained[:weekly].size} weekly, " \
           "#{retained[:monthly].size} monthly, #{retained[:yearly].size} yearly"
    end
  end
end

# Main execution
validate_environment!

all_pids = []
successful_backups = 0
failed_backups = 0

Dir.foreach(PARENT_DIR) do |entry|
  next if entry == '.' || entry == '..'

  dir = File.join(PARENT_DIR, entry)
  if File.directory?(dir)
    pids = process_directory(dir)
    all_pids.concat(pids)
  end
end

# Wait for all backup processes to complete and track results
all_pids.each do |pid|
  _pid, status = Process.wait2(pid)
  if status.exitstatus == 0
    successful_backups += 1
  else
    failed_backups += 1
  end
end

# Clean up old backups after all processes are complete
Dir.foreach(PARENT_DIR) do |entry|
  next if entry == '.' || entry == '..'

  dir = File.join(PARENT_DIR, entry)
  cleanup_old_backups(dir) if File.directory?(dir)
end

# Send summary notification
if successful_backups > 0 || failed_backups > 0
  summary = "Backup complete: #{successful_backups} succeeded, #{failed_backups} failed"
  puts summary unless OPTIONS[:quiet]
  post_to_slack(summary) if failed_backups == 0 && successful_backups > 0
end
