require 'fileutils'
require 'net/http'
require 'json'
require 'time'
require 'optparse'
require 'shellwords'

module BackupService
  class Config
    attr_accessor :parent_dir, :dest_dir, :slack_webhook_url, :quiet,
                  :backup_interval_minutes, :retain_hourly, :retain_daily,
                  :retain_weekly, :retain_monthly, :retain_yearly, :pg_globals_url

    def initialize
      @parent_dir = ENV['PARENT_DIR']
      @dest_dir = ENV['DEST_DIR']
      @slack_webhook_url = ENV['SLACK_WEBHOOK_URL']
      @pg_globals_url = ENV['PG_GLOBALS_URL']
      @quiet = false
      @backup_interval_minutes = (ENV['BACKUP_INTERVAL_MINUTES'] || '60').to_i
      @retain_hourly = (ENV['BACKUP_RETAIN_HOURLY'] || '6').to_i
      @retain_daily = (ENV['BACKUP_RETAIN_DAILY'] || '6').to_i
      @retain_weekly = (ENV['BACKUP_RETAIN_WEEKLY'] || '6').to_i
      @retain_monthly = (ENV['BACKUP_RETAIN_MONTHLY'] || '6').to_i
      @retain_yearly = (ENV['BACKUP_RETAIN_YEARLY'] || '6').to_i
    end

    def validate!
      errors = []
      errors << "PARENT_DIR environment variable is not set" if @parent_dir.nil? || @parent_dir.empty?
      errors << "DEST_DIR environment variable is not set" if @dest_dir.nil? || @dest_dir.empty?
      errors << "PARENT_DIR does not exist: #{@parent_dir}" if @parent_dir && !@parent_dir.empty? && !File.directory?(@parent_dir)
      errors
    end
  end

  class Backup
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def post_to_slack(message)
      return if config.slack_webhook_url.nil? || config.slack_webhook_url.empty?

      uri = URI(config.slack_webhook_url)
      payload = { text: message }.to_json
      headers = { 'Content-Type' => 'application/json' }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      request = Net::HTTP::Post.new(uri.path, headers)
      request.body = payload

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        puts "Failed to send message to Slack: #{response.body}" unless config.quiet
      end
    rescue StandardError => e
      puts "Exception when posting to Slack: #{e.message}" unless config.quiet
    end

    def backup_qdrant(host, port, collection, api_key, backup_file)
      base_url = "http://#{host}:#{port}"
      headers = { 'Content-Type' => 'application/json' }
      headers['api-key'] = api_key if api_key && !api_key.empty?

      begin
        uri = URI("#{base_url}/collections/#{collection}/snapshots")
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 30
        http.read_timeout = 300

        request = Net::HTTP::Post.new(uri.path, headers)
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          error_message = "Qdrant snapshot creation failed for #{collection}: #{response.code} #{response.body}"
          puts error_message unless config.quiet
          post_to_slack(error_message)
          return false
        end

        result = JSON.parse(response.body)
        snapshot_name = result.dig('result', 'name')

        unless snapshot_name
          error_message = "Qdrant snapshot creation returned no snapshot name for #{collection}"
          puts error_message unless config.quiet
          post_to_slack(error_message)
          return false
        end

        puts "Created Qdrant snapshot: #{snapshot_name}" unless config.quiet

        download_uri = URI("#{base_url}/collections/#{collection}/snapshots/#{snapshot_name}")
        download_http = Net::HTTP.new(download_uri.host, download_uri.port)
        download_http.read_timeout = 600

        download_request = Net::HTTP::Get.new(download_uri.path, headers)

        File.open(backup_file, 'wb') do |file|
          download_http.request(download_request) do |download_response|
            unless download_response.is_a?(Net::HTTPSuccess)
              error_message = "Qdrant snapshot download failed for #{collection}: #{download_response.code}"
              puts error_message unless config.quiet
              post_to_slack(error_message)
              return false
            end

            download_response.read_body do |chunk|
              file.write(chunk)
            end
          end
        end

        puts "Downloaded Qdrant snapshot to #{backup_file}" unless config.quiet

        delete_uri = URI("#{base_url}/collections/#{collection}/snapshots/#{snapshot_name}")
        delete_http = Net::HTTP.new(delete_uri.host, delete_uri.port)
        delete_request = Net::HTTP::Delete.new(delete_uri.path, headers)
        delete_response = delete_http.request(delete_request)

        if delete_response.is_a?(Net::HTTPSuccess)
          puts "Deleted remote Qdrant snapshot: #{snapshot_name}" unless config.quiet
        else
          puts "Warning: Failed to delete remote Qdrant snapshot #{snapshot_name}: #{delete_response.code}" unless config.quiet
        end

        true
      rescue StandardError => e
        error_message = "Qdrant backup error for #{collection}: #{e.message}"
        puts error_message unless config.quiet
        post_to_slack(error_message)
        false
      end
    end

    def extract_pg_server_info(db_url)
      if db_url =~ /^postgresql:\/\/([^:]*):([^@]*)@([^:]*):(\d+)\/(.*)$/
        { user: $1, password: $2, host: $3, port: $4 }
      else
        nil
      end
    end

    def build_pg_dumpall_command(server_info, backup_file)
      env_prefix = "PGPASSWORD=#{Shellwords.escape(server_info[:password])}"
      "#{env_prefix} pg_dumpall -h #{Shellwords.escape(server_info[:host])} -p #{Shellwords.escape(server_info[:port])} -U #{Shellwords.escape(server_info[:user])} --globals-only > #{Shellwords.escape(backup_file)} 2>&1"
    end

    def backup_pg_globals(server_info, backup_file)
      command = build_pg_dumpall_command(server_info, backup_file)
      output = `#{command}`
      if $?.exitstatus != 0
        File.delete(backup_file) if File.exist?(backup_file)

        if output.include?('permission denied')
          puts "Warning: Skipping PostgreSQL globals backup - insufficient privileges (requires superuser)" unless config.quiet
          return :skipped
        end

        error_message = "Error backing up PostgreSQL globals from #{server_info[:host]}:#{server_info[:port]}\nOutput: #{output}"
        puts error_message unless config.quiet
        post_to_slack(error_message)
        return false
      else
        compress_file(backup_file)
        return true
      end
    end

    def build_backup_command(db_url, backup_file)
      case db_url
      when /^postgresql:\/\/([^:]*):([^@]*)@([^:]*):(\d+)\/(.*)$/
        user, password, host, port, dbname = $1, $2, $3, $4, $5
        env_prefix = "PGPASSWORD=#{Shellwords.escape(password)}"
        "#{env_prefix} pg_dump -h #{Shellwords.escape(host)} -p #{Shellwords.escape(port)} -U #{Shellwords.escape(user)} -d #{Shellwords.escape(dbname)} -F c -b -v -f #{Shellwords.escape(backup_file)} 2>&1"
      when /^mysql:\/\/([^:]*):([^@]*)@([^:]*):(\d+)\/(.*)$/
        user, password, host, port, dbname = $1, $2, $3, $4, $5
        "mysqldump -h #{Shellwords.escape(host)} -P #{Shellwords.escape(port)} -u #{Shellwords.escape(user)} -p#{Shellwords.escape(password)} #{Shellwords.escape(dbname)} > #{Shellwords.escape(backup_file)} 2>&1"
      when /^sqlite:\/\/(\/.*)$/
        db_path = $1
        "sqlite3 #{Shellwords.escape(db_path)} .dump > #{Shellwords.escape(backup_file)} 2>&1"
      else
        nil
      end
    end

    def backup_database(db_url, backup_file)
      if db_url =~ /^qdrant:\/\/(?:([^@]+)@)?([^:]+):(\d+)\/(.+)$/
        api_key, host, port, collection = $1, $2, $3, $4
        success = backup_qdrant(host, port, collection, api_key, backup_file)
        compress_file(backup_file) if success
        return success
      end

      command = build_backup_command(db_url, backup_file)
      unless command
        error_message = "Unsupported database URL format: #{db_url}"
        puts error_message unless config.quiet
        post_to_slack(error_message)
        return false
      end

      output = `#{command}`
      if $?.exitstatus != 0
        error_message = "Error backing up database: #{db_url}\nOutput: #{output}"
        puts error_message unless config.quiet
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
        puts "Compressed and deleted original backup file: #{file}" unless config.quiet
        true
      else
        error_message = "Error compressing file: #{file}"
        puts error_message unless config.quiet
        post_to_slack(error_message)
        false
      end
    end

    def parse_database_urls(env_file)
      db_urls = []
      File.foreach(env_file) do |line|
        if line =~ /^BACKUP_DATABASE_URLS=(.*)$/
          urls = $1.strip
          urls = urls[1..-2] if (urls.start_with?('"') && urls.end_with?('"')) ||
                                (urls.start_with?("'") && urls.end_with?("'"))
          db_urls = urls.split(',').map { |url| url.strip.gsub(/["']/, '') }
          break
        end
      end
      db_urls
    end

    def generate_backup_filename(db_url, timestamp)
      case db_url
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
      when /^qdrant:\/\/(?:[^@]+@)?[^:]+:\d+\/(.+)$/
        collection = $1
        "backup-#{collection}-#{timestamp}.snapshot"
      else
        nil
      end
    end

    def process_directory(dir)
      env_file = File.join(dir, ".env")
      return { pids: [], pg_servers: [] } unless File.exist?(env_file)

      db_urls = parse_database_urls(env_file)
      pids = []
      pg_servers = []

      db_urls.each do |db_url|
        timestamp = Time.now.strftime("%Y%m%d%H%M%S")
        backup_subdir = File.join(config.dest_dir, File.basename(dir))
        FileUtils.mkdir_p(backup_subdir)

        backup_filename = generate_backup_filename(db_url, timestamp)
        next unless backup_filename

        pg_info = extract_pg_server_info(db_url)
        pg_servers << pg_info if pg_info

        backup_file = File.join(backup_subdir, backup_filename)
        puts "Backing up database to #{backup_file}" unless config.quiet

        pid = fork do
          success = backup_database(db_url, backup_file)
          exit(success ? 0 : 1)
        end
        pids << pid
      end

      { pids: pids, pg_servers: pg_servers }
    end

    def parse_backup_timestamp(filename)
      if filename =~ /backup-.*-(\d{14})\.(sql|snapshot)(\.bz2)?$/
        Time.strptime($1, "%Y%m%d%H%M%S")
      else
        nil
      end
    end

    def extract_dbname(filename)
      if filename =~ /backup-(.+)-\d{14}\.(sql|snapshot)(\.bz2)?$/
        $1
      else
        nil
      end
    end

    def categorize_backups(backup_files)
      hourly = {}
      daily = {}
      weekly = {}
      monthly = {}
      yearly = {}

      sorted_files = backup_files.map { |f| [f, parse_backup_timestamp(File.basename(f))] }
                                 .reject { |_, ts| ts.nil? }
                                 .sort_by { |_, ts| -ts.to_i }

      sorted_files.each do |file, timestamp|
        hour_key = timestamp.strftime("%Y-%m-%d-%H")
        day_key = timestamp.strftime("%Y-%m-%d")
        week_key = timestamp.strftime("%G-%V")
        month_key = timestamp.strftime("%Y-%m")
        year_key = timestamp.strftime("%Y")

        hourly[hour_key] ||= file
        daily[day_key] ||= file
        weekly[week_key] ||= file
        monthly[month_key] ||= file
        yearly[year_key] ||= file
      end

      {
        hourly: hourly.values.take(config.retain_hourly),
        daily: daily.values.take(config.retain_daily),
        weekly: weekly.values.take(config.retain_weekly),
        monthly: monthly.values.take(config.retain_monthly),
        yearly: yearly.values.take(config.retain_yearly)
      }
    end

    def cleanup_old_backups(dir)
      backup_subdir = File.join(config.dest_dir, File.basename(dir))
      return unless File.directory?(backup_subdir)

      all_files = Dir.glob(File.join(backup_subdir, 'backup-*.{sql,snapshot}.bz2')) +
                  Dir.glob(File.join(backup_subdir, 'backup-*.{sql,snapshot}'))

      files_by_db = all_files.group_by { |f| extract_dbname(File.basename(f)) }
                             .reject { |k, _| k.nil? }

      files_by_db.each do |dbname, files|
        retained = categorize_backups(files)

        files_to_keep = (retained[:hourly] + retained[:daily] + retained[:weekly] +
                         retained[:monthly] + retained[:yearly]).uniq

        files.each do |file|
          unless files_to_keep.include?(file)
            File.delete(file)
            puts "Deleted old backup file: #{file}" unless config.quiet
          end
        end

        unless config.quiet
          puts "Retention for #{dbname}: #{retained[:hourly].size} hourly, " \
               "#{retained[:daily].size} daily, #{retained[:weekly].size} weekly, " \
               "#{retained[:monthly].size} monthly, #{retained[:yearly].size} yearly"
        end
      end
    end

    def run_backup_cycle
      all_pids = []
      all_pg_servers = []
      successful_backups = 0
      failed_backups = 0

      Dir.foreach(config.parent_dir) do |entry|
        next if entry == '.' || entry == '..'

        dir = File.join(config.parent_dir, entry)
        if File.directory?(dir)
          result = process_directory(dir)
          all_pids.concat(result[:pids])
          all_pg_servers.concat(result[:pg_servers])
        end
      end

      all_pids.each do |pid|
        _pid, status = Process.wait2(pid)
        if status.exitstatus == 0
          successful_backups += 1
        else
          failed_backups += 1
        end
      end

      pg_globals_servers = if config.pg_globals_url && !config.pg_globals_url.empty?
        server_info = extract_pg_server_info(config.pg_globals_url)
        server_info ? [server_info] : []
      elsif all_pg_servers.any?
        all_pg_servers.uniq { |s| "#{s[:host]}:#{s[:port]}" }
      else
        []
      end

      if pg_globals_servers.any?
        backup_subdir = File.join(config.dest_dir, "postgresql")
        FileUtils.mkdir_p(backup_subdir)

        pg_globals_servers.each do |server_info|
          timestamp = Time.now.strftime("%Y%m%d%H%M%S")
          server_id = "#{server_info[:host]}-#{server_info[:port]}"
          backup_file = File.join(backup_subdir, "backup-globals-#{server_id}-#{timestamp}.sql")
          puts "Backing up PostgreSQL globals from #{server_info[:host]}:#{server_info[:port]} to #{backup_file}" unless config.quiet

          result = backup_pg_globals(server_info, backup_file)
          case result
          when true
            successful_backups += 1
          when :skipped
            # Permission denied - don't count as success or failure
          else
            failed_backups += 1
          end
        end
      end

      Dir.foreach(config.parent_dir) do |entry|
        next if entry == '.' || entry == '..'

        dir = File.join(config.parent_dir, entry)
        cleanup_old_backups(dir) if File.directory?(dir)
      end

      cleanup_old_backups(File.join(config.parent_dir, "postgresql")) if pg_globals_servers.any?

      if successful_backups > 0 || failed_backups > 0
        summary = "Backup complete: #{successful_backups} succeeded, #{failed_backups} failed"
        puts summary unless config.quiet
        post_to_slack(summary) if failed_backups == 0 && successful_backups > 0
      end

      { successful: successful_backups, failed: failed_backups }
    end

    def run
      errors = config.validate!
      unless errors.empty?
        errors.each { |e| puts "ERROR: #{e}" }
        exit 1
      end

      puts "Starting backup service (interval: #{config.backup_interval_minutes} minutes)" unless config.quiet

      loop do
        start_time = Time.now
        puts "Starting backup cycle at #{start_time}" unless config.quiet

        run_backup_cycle

        elapsed = Time.now - start_time
        puts "Backup cycle completed in #{elapsed.round(1)} seconds" unless config.quiet

        sleep_seconds = config.backup_interval_minutes * 60
        next_run = Time.now + sleep_seconds
        puts "Next backup at #{next_run}" unless config.quiet

        sleep(sleep_seconds)
      end
    end
  end
end

if __FILE__ == $0
  config = BackupService::Config.new

  OptionParser.new do |opts|
    opts.banner = "Usage: backup.rb [options]"

    opts.on("--quiet", "Suppress all output") do
      config.quiet = true
    end
  end.parse!

  backup = BackupService::Backup.new(config)
  backup.run
end
