require 'fileutils'
require 'net/http'
require 'json'
require 'time'
require 'optparse'

# Parse command-line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: backup_script.rb [options]"

  opts.on("--quiet", "Suppress all output") do
    options[:quiet] = true
  end
end.parse!

PARENT_DIR = ENV['PARENT_DIR']
DEST_DIR = ENV['DEST_DIR']
SLACK_WEBHOOK_URL = ENV['SLACK_WEBHOOK_URL']

def post_to_slack(message)
  return if SLACK_WEBHOOK_URL.nil? || SLACK_WEBHOOK_URL.empty?

  uri = URI(SLACK_WEBHOOK_URL)
  payload = { text: message }.to_json
  headers = { 'Content-Type' => 'application/json' }

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Post.new(uri.path, headers)
  request.body = payload

  response = http.request(request)
  unless response.is_a?(Net::HTTPSuccess)
    puts "Failed to send message to Slack: #{response.body}" unless options[:quiet]
  end
rescue StandardError => e
  puts "Exception when posting to Slack: #{e.message}" unless options[:quiet]
end

def backup_database(dir, db_url, backup_file)
  command = case db_url
            when /^postgresql:\/\/(.*):(.*)@(.*):(\d+)\/(.*)$/
              user, password, host, port, dbname = $1, $2, $3, $4, $5
              "PGPASSWORD='#{password}' pg_dump -h #{host} -p #{port} -U #{user} -d #{dbname} -F c -b -v -f #{backup_file} 2>&1"
            when /^mysql:\/\/(.*):(.*)@(.*):(\d+)\/(.*)$/
              user, password, host, port, dbname = $1, $2, $3, $4, $5
              "mysqldump -h #{host} -P #{port} -u #{user} -p#{password} #{dbname} > #{backup_file} 2>&1"
            when /^sqlite:\/\/(\/.*)$/
              db_path = $1
              "sqlite3 #{db_path} .dump > #{backup_file} 2>&1"
            when /^redis:\/\/(.*):(.*)@(.*):(\d+)\/(.*)$/
              host, port, dbname = $3, $4, $5
              "redis-cli -h #{host} -p #{port} -n #{dbname} --rdb #{backup_file} 2>&1"
            else
              error_message = "Unsupported database URL format: #{db_url}"
              puts error_message unless options[:quiet]
              post_to_slack(error_message)
              return false
            end

  pid = fork do
    output = `#{command}`
    if $?.exitstatus != 0
      error_message = "Error backing up database: #{db_url}\nOutput: #{output}"
      puts error_message unless options[:quiet]
      post_to_slack(error_message)
    else
      compress_file(backup_file)
    end
  end

  Process.detach(pid)
end

def compress_file(file)
  compressed_file = "#{file}.bz2"
  system("bzip2 -c #{file} > #{compressed_file}")
  if $?.exitstatus == 0
    File.delete(file)
    puts "Compressed and deleted original backup file: #{file}" unless options[:quiet]
  else
    error_message = "Error compressing file: #{file}"
    puts error_message unless options[:quiet]
    post_to_slack(error_message)
  end
end

def process_directory(dir)
  env_file = File.join(dir, ".env")
  return unless File.exist?(env_file)

  db_urls = []
  File.foreach(env_file) do |line|
    if line =~ /^BACKUP_DATABASE_URLS=(.*)$/
      urls = $1.strip
      urls = urls[1..-2] if urls.start_with?('"') && urls.end_with?('"')  # Remove enclosing quotes
      db_urls = urls.split(',').map { |url| url.strip.gsub('"', '') }  # Remove internal quotes
      break
    end
  end

  db_urls.each do |db_url|
    timestamp = Time.now.strftime("%Y%m%d%H%M%S")
    backup_subdir = File.join(DEST_DIR, File.basename(dir))
    FileUtils.mkdir_p(backup_subdir)

    backup_filename = case db_url
                      when /^postgresql:\/\/(.*):(.*)@(.*):(\d+)\/(.*)$/
                        dbname = $5
                        "backup-#{dbname}-#{timestamp}.sql"
                      when /^mysql:\/\/(.*):(.*)@(.*):(\d+)\/(.*)$/
                        dbname = $5
                        "backup-#{dbname}-#{timestamp}.sql"
                      when /^sqlite:\/\/(\/.*)$/
                        db_path = $1
                        dbname = File.basename(db_path, ".*")
                        "backup-#{dbname}-#{timestamp}.sql"
                      when /^redis:\/\/(.*):(.*)@(.*):(\d+)\/(.*)$/
                        dbname = $5
                        "backup-#{dbname}-#{timestamp}.rdb"
                      else
                        next
                      end

    backup_file = File.join(backup_subdir, backup_filename)
    puts "Backing up database to #{backup_file}" unless options[:quiet]
    backup_database(dir, db_url, backup_file)
  end
end

def cleanup_old_backups(dir)
  backup_subdir = File.join(DEST_DIR, File.basename(dir))
  backup_files = Dir.glob(File.join(backup_subdir, "backup-*.sql.bz2")).sort_by { |f| File.mtime(f) }
  if backup_files.size > 5
    files_to_delete = backup_files[0..-(6)]
    files_to_delete.each do |file|
      File.delete(file)
      puts "Deleted old backup file: #{file}" unless options[:quiet]
    end
  end
end

Dir.foreach(PARENT_DIR) do |entry|
  next if entry == '.' || entry == '..'

  dir = File.join(PARENT_DIR, entry)
  process_directory(dir) if File.directory?(dir)
end

# Clean up old backups after all processes are complete
Process.waitall
Dir.foreach(PARENT_DIR) do |entry|
  next if entry == '.' || entry == '..'

  dir = File.join(PARENT_DIR, entry)
  cleanup_old_backups(dir) if File.directory?(dir)
end
