require 'English'
require 'fileutils'
require 'net/http'
require 'json'
require 'time'
require 'optparse'
require 'shellwords'
require 'open3'

module BackupService
  # An age recipient is either a native age public key (bech32, always 62
  # characters) or an SSH public key, which may carry a trailing comment.
  AGE_RECIPIENT_PATTERN = /\A(?:age1[0-9a-z]{58}\z|ssh-(?:ed25519|rsa)\s+\S+)/

  # Every age file begins with this version line.
  AGE_HEADER = 'age-encryption.org/v1'.freeze

  def self.valid_age_recipient?(recipient)
    !recipient.nil? && recipient.match?(AGE_RECIPIENT_PATTERN)
  end

  def self.parse_recipient_list(value)
    return [] if value.nil? || value.strip.empty?

    value.split(',').map(&:strip).reject(&:empty?)
  end

  def self.read_recipients_file(path)
    File.readlines(path).map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
  end

  # An age file is binary, but its first line is always the version header.
  # Checking it catches a truncated or empty result being promoted to a backup.
  def self.age_file?(path)
    return false unless File.exist?(path) && File.size(path).positive?

    File.open(path, 'rb') { |f| f.read(AGE_HEADER.bytesize) } == AGE_HEADER
  rescue StandardError
    false
  end

  # When a whole-line quoted value contains multiple URLs, split on commas that
  # introduce the next scheme rather than commas inside a URL.
  URL_LIST_SCHEME_SPLIT = %r{,(?=(?:postgres(?:ql)?|mysql2?|sqlite|qdrant)://)}

  def self.split_database_url_list(value)
    return [] if value.nil? || value.strip.empty?

    urls = split_quoted_csv(value.strip)
    if urls.size == 1 && urls.first.include?(',')
      combined = urls.first
      urls = combined.split(URL_LIST_SCHEME_SPLIT) if combined.scan(%r{[a-z]+://}).size > 1
    end
    urls.map { |url| url.gsub(/\A["']|["']\z/, '') }
  end

  def self.split_quoted_csv(value)
    urls = []
    current = +''
    in_quotes = false
    quote_char = nil

    value.each_char do |char|
      case char
      when '"', "'"
        if in_quotes && char == quote_char
          in_quotes = false
          quote_char = nil
        elsif !in_quotes
          in_quotes = true
          quote_char = char
        else
          current << char
        end
      when ','
        if in_quotes
          current << char
        else
          urls << current.strip unless current.strip.empty?
          current = +''
        end
      else
        current << char
      end
    end

    urls << current.strip unless current.strip.empty?
    urls
  end

  class Config
    attr_accessor :parent_dir, :source_directories, :dest_dir, :slack_webhook_url, :quiet, :debug,
                  :backup_interval_minutes, :retain_hourly, :retain_daily,
                  :retain_weekly, :retain_monthly, :retain_yearly, :pg_globals_url,
                  :encryption_recipients, :encryption_recipients_file

    def initialize
      @parent_dir = ENV['PARENT_DIR'] || '/opt'
      @source_directories = parse_source_directories(ENV.fetch('SOURCE_DIRECTORIES', nil))
      @dest_dir = ENV.fetch('DEST_DIR', nil)
      @slack_webhook_url = ENV.fetch('SLACK_WEBHOOK_URL', nil)
      @pg_globals_url = ENV.fetch('PG_GLOBALS_URL', nil)
      @encryption_recipients = BackupService.parse_recipient_list(ENV.fetch('BACKUP_ENCRYPTION_RECIPIENTS', nil))
      @encryption_recipients_file = ENV.fetch('BACKUP_ENCRYPTION_RECIPIENTS_FILE', nil)
      @quiet = false
      @debug = ENV['DEBUG'] == '1'
      @backup_interval_minutes = (ENV['BACKUP_INTERVAL_MINUTES'] || '60').to_i
      @retain_hourly = (ENV['BACKUP_RETAIN_HOURLY'] || '6').to_i
      @retain_daily = (ENV['BACKUP_RETAIN_DAILY'] || '6').to_i
      @retain_weekly = (ENV['BACKUP_RETAIN_WEEKLY'] || '6').to_i
      @retain_monthly = (ENV['BACKUP_RETAIN_MONTHLY'] || '6').to_i
      @retain_yearly = (ENV['BACKUP_RETAIN_YEARLY'] || '6').to_i
    end

    def parse_source_directories(value)
      return [] if value.nil? || value.empty?

      value.split(',').map(&:strip).reject(&:empty?)
    end

    def encryption_enabled?
      !@encryption_recipients.empty?
    end

    def validate!
      errors = []
      errors << 'SOURCE_DIRECTORIES environment variable is not set' if @source_directories.empty?
      errors << 'DEST_DIR environment variable is not set' if @dest_dir.nil? || @dest_dir.empty?

      @source_directories.each do |src_dir|
        full_path = File.join(@parent_dir, src_dir)
        errors << "Source directory does not exist: #{full_path}" unless File.directory?(full_path)
      end

      errors.concat(resolve_encryption_recipients!)

      errors
    end

    # Merges BACKUP_ENCRYPTION_RECIPIENTS_FILE into the recipient list and checks
    # every key up front, so a misconfigured deployment fails at startup rather
    # than silently producing backups nobody can decrypt.
    def resolve_encryption_recipients!
      errors = []
      path = @encryption_recipients_file

      if path && !path.empty?
        if !File.file?(path)
          errors << "BACKUP_ENCRYPTION_RECIPIENTS_FILE does not exist: #{path}"
        elsif !File.readable?(path)
          errors << "BACKUP_ENCRYPTION_RECIPIENTS_FILE is not readable: #{path}"
        else
          from_file = BackupService.read_recipients_file(path)
          errors << "BACKUP_ENCRYPTION_RECIPIENTS_FILE contains no recipients: #{path}" if from_file.empty?
          @encryption_recipients = (@encryption_recipients + from_file).uniq
        end
      end

      @encryption_recipients.each do |recipient|
        next if BackupService.valid_age_recipient?(recipient)

        errors << "Invalid age recipient (expected age1... or an SSH public key): #{recipient}"
      end

      errors
    end
  end

  class Backup
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def debug(message)
      puts "[DEBUG] #{message}" if config.debug
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
      puts "Failed to send message to Slack: #{response.body}" if !response.is_a?(Net::HTTPSuccess) && !config.quiet
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
          unless config.quiet
            puts "Warning: Failed to delete remote Qdrant snapshot #{snapshot_name}: #{delete_response.code}"
          end
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
      return unless db_url =~ %r{^postgres(?:ql)?://([^:]*):([^@]*)@([^/:]+)(?::(\d+))?/(.*)$}

      { user: ::Regexp.last_match(1), password: ::Regexp.last_match(2), host: ::Regexp.last_match(3),
        port: ::Regexp.last_match(4) || '5432' }
    end

    def build_pg_dumpall_command(server_info, backup_file)
      env_prefix = "PGPASSWORD=#{Shellwords.escape(server_info[:password])}"
      "#{env_prefix} pg_dumpall -h #{Shellwords.escape(server_info[:host])} -p #{Shellwords.escape(server_info[:port])} -U #{Shellwords.escape(server_info[:user])} --globals-only > #{Shellwords.escape(backup_file)} 2>&1"
    end

    def backup_pg_globals(server_info, backup_file)
      command = build_pg_dumpall_command(server_info, backup_file)
      output = `#{command}`
      return compress_and_encrypt_file(backup_file) unless $CHILD_STATUS.exitstatus != 0

      FileUtils.rm_f(backup_file)

      if output.include?('permission denied')
        unless config.quiet
          puts 'Warning: Skipping PostgreSQL globals backup - insufficient privileges (requires superuser)'
        end
        return :skipped
      end

      error_message = "Error backing up PostgreSQL globals from #{server_info[:host]}:#{server_info[:port]}\nOutput: #{output}"
      puts error_message unless config.quiet
      post_to_slack(error_message)
      false
    end

    def build_backup_command(db_url, backup_file)
      case db_url
      when %r{^postgres(?:ql)?://([^:]*):([^@]*)@([^/:]+)(?::(\d+))?/(.*)$}
        user = ::Regexp.last_match(1)
        password = ::Regexp.last_match(2)
        host = ::Regexp.last_match(3)
        port = ::Regexp.last_match(4) || '5432'
        dbname = ::Regexp.last_match(5)
        env_prefix = "PGPASSWORD=#{Shellwords.escape(password)}"
        "#{env_prefix} pg_dump -h #{Shellwords.escape(host)} -p #{Shellwords.escape(port)} -U #{Shellwords.escape(user)} -d #{Shellwords.escape(dbname)} -F c -b -v -f #{Shellwords.escape(backup_file)} 2>&1"
      when %r{^mysql2?://([^:]*):([^@]*)@([^/:]+)(?::(\d+))?/(.*)$}
        user = ::Regexp.last_match(1)
        password = ::Regexp.last_match(2)
        host = ::Regexp.last_match(3)
        port = ::Regexp.last_match(4) || '3306'
        dbname = ::Regexp.last_match(5)
        "mysqldump -h #{Shellwords.escape(host)} -P #{Shellwords.escape(port)} -u #{Shellwords.escape(user)} -p#{Shellwords.escape(password)} #{Shellwords.escape(dbname)} > #{Shellwords.escape(backup_file)} 2>&1"
      when %r{^sqlite://(/.*)$}
        db_path = ::Regexp.last_match(1)
        "sqlite3 #{Shellwords.escape(db_path)} .dump > #{Shellwords.escape(backup_file)} 2>&1"
      end
    end

    def backup_database(db_url, backup_file)
      if db_url =~ %r{^qdrant://(?:([^@]+)@)?([^:]+):(\d+)/(.+)$}
        api_key = ::Regexp.last_match(1)
        host = ::Regexp.last_match(2)
        port = ::Regexp.last_match(3)
        collection = ::Regexp.last_match(4)
        return false unless backup_qdrant(host, port, collection, api_key, backup_file)

        return compress_and_encrypt_file(backup_file)
      end

      command = build_backup_command(db_url, backup_file)
      unless command
        error_message = "Unsupported database URL format: #{db_url}"
        puts error_message unless config.quiet
        post_to_slack(error_message)
        return false
      end

      if db_url =~ %r{^sqlite://(/.*)$}
        db_path = ::Regexp.last_match(1)
        unless File.exist?(db_path)
          error_message = "SQLite database file not found: #{db_path}"
          puts error_message unless config.quiet
          post_to_slack(error_message)
          return false
        end
      end

      output = `#{command}`
      return compress_and_encrypt_file(backup_file) unless $CHILD_STATUS.exitstatus != 0

      error_message = "Error backing up database: #{db_url}\nOutput: #{output}"
      error_message += "\nDatabase path: #{::Regexp.last_match(1)}" if db_url =~ %r{^sqlite://(/.*)$}
      puts error_message unless config.quiet
      post_to_slack(error_message)
      false
    end

    def compressed_backup_path(file)
      config.encryption_enabled? ? "#{file}.bz2.age" : "#{file}.bz2"
    end

    def pipeline_stages(file, recipients)
      stages = [['bzip2', '-c', file]]
      stages << (['age'] + recipients.flat_map { |r| ['-r', r] }) unless recipients.empty?
      stages
    end

    # Compresses, and when recipients are configured encrypts, in a single
    # pipeline so the compressed plaintext never reaches disk. Fails closed:
    # on any error the partial output and the plaintext dump are both removed
    # rather than leaving an unencrypted backup behind.
    def compress_and_encrypt_file(file)
      recipients = config.encryption_recipients
      encrypting = !recipients.empty?
      output_file = encrypting ? "#{file}.bz2.age" : "#{file}.bz2"
      temp_file = "#{output_file}.part"
      failure = nil

      succeeded = begin
        statuses = Open3.pipeline(*pipeline_stages(file, recipients), out: temp_file)
        failed = statuses.reject { |status| status.exitstatus.zero? }

        if failed.any?
          failure = "exit status #{failed.map(&:exitstatus).join(', ')}"
          false
        elsif !File.exist?(temp_file) || File.empty?(temp_file)
          failure = 'output is empty'
          false
        elsif encrypting && !BackupService.age_file?(temp_file)
          failure = 'output is not a valid age file'
          false
        else
          true
        end
      rescue StandardError => e
        failure = e.message
        false
      end

      if succeeded
        File.rename(temp_file, output_file)
        FileUtils.rm_f(file)
        action = encrypting ? 'Compressed, encrypted' : 'Compressed'
        puts "#{action} and deleted original backup file: #{file}" unless config.quiet
        true
      else
        FileUtils.rm_f(temp_file)
        FileUtils.rm_f(file)
        action = encrypting ? 'compressing/encrypting' : 'compressing'
        error_message = "Error #{action} file: #{file} (#{failure})"
        puts error_message unless config.quiet
        post_to_slack(error_message)
        false
      end
    end

    def parse_database_urls(env_file)
      db_urls = []
      File.foreach(env_file) do |line|
        next if line.strip.start_with?('#')

        next unless line =~ /^BACKUP_DATABASE_URLS=(.*)$/

        db_urls = BackupService.split_database_url_list(::Regexp.last_match(1))
        break
      end
      db_urls
    end

    def generate_backup_filename(db_url, timestamp)
      case db_url
      when %r{^postgres(?:ql)?://([^:]*):([^@]*)@([^/:]+)(?::(\d+))?/(.*)$}
        dbname = ::Regexp.last_match(5)
        "backup-#{dbname}-#{timestamp}.sql"
      when %r{^mysql2?://([^:]*):([^@]*)@([^/:]+)(?::(\d+))?/(.*)$}
        dbname = ::Regexp.last_match(5)
        "backup-#{dbname}-#{timestamp}.sql"
      when %r{^sqlite://(/.*)$}
        db_path = ::Regexp.last_match(1)
        dbname = File.basename(db_path, '.*')
        "backup-#{dbname}-#{timestamp}.sql"
      when %r{^qdrant://(?:[^@]+@)?[^:]+:\d+/(.+)$}
        collection = ::Regexp.last_match(1)
        "backup-#{collection}-#{timestamp}.snapshot"
      end
    end

    def process_directory(dir)
      env_file = File.join(dir, '.env')
      debug "=== Processing directory: #{dir} ==="
      debug "Looking for .env file: #{env_file}"

      unless File.exist?(env_file)
        debug 'No .env file found, skipping directory'
        return { pids: [], pg_servers: [] }
      end

      debug '.env file found'

      db_urls = parse_database_urls(env_file)
      debug "BACKUP_DATABASE_URLS found: #{db_urls.size} URL(s)"
      db_urls.each_with_index do |url, i|
        db_type = case url
                  when /^postgres(?:ql)?:/ then 'PostgreSQL'
                  when /^mysql2?:/ then 'MySQL'
                  when /^sqlite:/ then 'SQLite'
                  when /^qdrant:/ then 'Qdrant'
                  else 'Unknown'
                  end
        debug "  [#{i + 1}] #{db_type}: #{url.gsub(/:[^:@]+@/, ':****@')}"
      end

      pids = []
      pg_servers = []

      db_urls.each do |db_url|
        timestamp = Time.now.strftime('%Y%m%d%H%M%S')
        backup_subdir = File.join(config.dest_dir, File.basename(dir))
        FileUtils.mkdir_p(backup_subdir)

        backup_filename = generate_backup_filename(db_url, timestamp)
        unless backup_filename
          debug 'Could not generate backup filename for URL, skipping'
          next
        end

        debug "Generated backup filename: #{backup_filename}"
        debug "Backup will be stored in: #{backup_subdir}"

        pg_info = extract_pg_server_info(db_url)
        pg_servers << pg_info if pg_info

        backup_file = File.join(backup_subdir, backup_filename)
        puts "Backing up database to #{backup_file}" unless config.quiet

        pid = fork do
          success = backup_database(db_url, backup_file)
          exit(success ? 0 : 1)
        end
        pids << pid
        debug "Forked backup process with PID: #{pid}"
      end

      debug "Total backup processes started: #{pids.size}"
      { pids: pids, pg_servers: pg_servers }
    end

    def parse_backup_timestamp(filename)
      return unless filename =~ /backup-.*-(\d{14})\.(sql|snapshot)(\.bz2)?(\.age)?$/

      Time.strptime(::Regexp.last_match(1), '%Y%m%d%H%M%S')
    end

    def extract_dbname(filename)
      return unless filename =~ /backup-(.+)-\d{14}\.(sql|snapshot)(\.bz2)?(\.age)?$/

      ::Regexp.last_match(1)
    end

    # Encrypted and unencrypted backups coexist during migration, so every
    # lookup has to consider both suffixes.
    BACKUP_SUFFIXES = ['bz2', 'bz2.age'].freeze

    def backup_glob_patterns(dir, dbname = nil)
      stem = dbname ? "backup-#{dbname}-*" : 'backup-*'
      BACKUP_SUFFIXES.map { |suffix| File.join(dir, "#{stem}.{sql,snapshot}.#{suffix}") }
    end

    def backup_glob(dir, dbname = nil)
      backup_glob_patterns(dir, dbname).flat_map { |pattern| Dir.glob(pattern) }
    end

    TIERS = %i[hourly daily weekly monthly yearly].freeze

    def tier_key_for_timestamp(tier, timestamp)
      case tier
      when :hourly then timestamp.strftime('%Y-%m-%d-%H')
      when :daily then timestamp.strftime('%Y-%m-%d')
      when :weekly then timestamp.strftime('%G-%V')
      when :monthly then timestamp.strftime('%Y-%m')
      when :yearly then timestamp.strftime('%Y')
      end
    end

    def tier_retention(tier)
      case tier
      when :hourly then config.retain_hourly
      when :daily then config.retain_daily
      when :weekly then config.retain_weekly
      when :monthly then config.retain_monthly
      when :yearly then config.retain_yearly
      end
    end

    def distribute_backup_to_tiers(backup_file, app_subdir)
      debug '=== Distributing backup to tiers ==='
      debug "Backup file: #{backup_file}"
      debug "App subdirectory: #{app_subdir}"

      unless File.exist?(backup_file)
        debug 'ERROR: File does not exist!'
        puts '  File does not exist!' unless config.quiet
        return
      end

      debug "File exists, size: #{File.size(backup_file)} bytes"

      timestamp = parse_backup_timestamp(File.basename(backup_file))
      unless timestamp
        debug "ERROR: Could not parse timestamp from filename: #{File.basename(backup_file)}"
        puts '  Could not parse timestamp from filename' unless config.quiet
        return
      end

      debug "Parsed timestamp: #{timestamp}"

      filename = File.basename(backup_file)
      puts "  Distributing #{filename} to tier directories" unless config.quiet

      debug ''
      debug '=== Tier Distribution Logic ==='
      debug 'Each tier keeps the newest backup for each time bucket.'
      debug 'Time buckets:'
      debug "  - hourly:  #{tier_key_for_timestamp(:hourly,
                                                   timestamp)} (retaining #{config.retain_hourly} most recent hours)"
      debug "  - daily:   #{tier_key_for_timestamp(:daily,
                                                   timestamp)} (retaining #{config.retain_daily} most recent days)"
      debug "  - weekly:  #{tier_key_for_timestamp(:weekly,
                                                   timestamp)} (retaining #{config.retain_weekly} most recent weeks)"
      debug "  - monthly: #{tier_key_for_timestamp(:monthly,
                                                   timestamp)} (retaining #{config.retain_monthly} most recent months)"
      debug "  - yearly:  #{tier_key_for_timestamp(:yearly,
                                                   timestamp)} (retaining #{config.retain_yearly} most recent years)"
      debug ''

      TIERS.each do |tier|
        tier_dir = File.join(app_subdir, tier.to_s)
        debug "Processing tier: #{tier}"
        debug "  Tier directory: #{tier_dir}"
        FileUtils.mkdir_p(tier_dir)
        debug "  Directory created/exists: #{File.directory?(tier_dir)}"

        debug "  Glob patterns: #{backup_glob_patterns(tier_dir).join(', ')}"
        existing_files = backup_glob(tier_dir)
        debug "  Existing files in tier: #{existing_files.size}"
        existing_files.each { |f| debug "    - #{File.basename(f)}" }

        tier_key = tier_key_for_timestamp(tier, timestamp)
        debug "  Current backup's tier key: #{tier_key}"

        existing_for_key = existing_files.find do |f|
          ts = parse_backup_timestamp(File.basename(f))
          ts && tier_key_for_timestamp(tier, ts) == tier_key
        end

        if existing_for_key
          debug "  Found existing backup for this time bucket: #{File.basename(existing_for_key)}"
          puts "  Skipping #{tier}/ - already have backup for this time bucket" unless config.quiet
        else
          dest_file = File.join(tier_dir, filename)
          debug "  No existing backup for this time bucket, copying to: #{dest_file}"
          FileUtils.cp(backup_file, dest_file)
          debug "  Copy successful: #{File.exist?(dest_file)}"
          puts "  Copied to #{tier}/" unless config.quiet
        end
      end

      debug "Deleting original backup file: #{backup_file}"
      File.delete(backup_file)
      debug 'Original file deleted'
      puts '  Deleted original file' unless config.quiet
    end

    # Newest first. When a plaintext and an encrypted copy of the same backup
    # both exist, keep the encrypted one rather than deciding arbitrarily.
    def retention_sort_key(file, timestamp)
      [-timestamp.to_i, file.end_with?('.age') ? 0 : 1, file]
    end

    def cleanup_tier(tier_dir, tier, dbname = nil)
      files = backup_glob(tier_dir, dbname)
      return if files.empty?

      files_by_db = files.group_by { |f| extract_dbname(File.basename(f)) }
                         .reject { |k, _| k.nil? }

      files_by_db.each do |db, db_files|
        buckets = {}
        db_files.each do |file|
          ts = parse_backup_timestamp(File.basename(file))
          next unless ts

          key = tier_key_for_timestamp(tier, ts)
          buckets[key] ||= []
          buckets[key] << [file, ts]
        end

        buckets.each_value do |bucket_files|
          sorted = bucket_files.sort_by { |file, ts| retention_sort_key(file, ts) }
          sorted[1..]&.each do |file, _|
            File.delete(file)
            puts "Deleted duplicate in #{tier}: #{file}" unless config.quiet
          end
        end

        tier_sym = tier.to_s.to_sym
        retention = tier_retention(tier_sym)
        remaining_files = backup_glob(tier_dir, db)
        sorted_remaining = remaining_files.map { |f| [f, parse_backup_timestamp(File.basename(f))] }
                                          .reject { |_, ts| ts.nil? }
                                          .sort_by { |file, ts| retention_sort_key(file, ts) }

        keys_seen = {}
        sorted_remaining.each do |file, ts|
          key = tier_key_for_timestamp(tier_sym, ts)
          if keys_seen[key] || keys_seen.size >= retention
            File.delete(file) unless keys_seen[key]
            puts "Deleted old #{tier} backup: #{file}" if !keys_seen[key] && !config.quiet
          else
            keys_seen[key] = true
          end
        end
      end
    end

    def cleanup_old_backups(dir)
      backup_subdir = File.join(config.dest_dir, File.basename(dir))
      return unless File.directory?(backup_subdir)

      TIERS.each do |tier|
        tier_dir = File.join(backup_subdir, tier.to_s)
        next unless File.directory?(tier_dir)

        cleanup_tier(tier_dir, tier)
      end

      retained_counts = {}
      TIERS.each do |tier|
        tier_dir = File.join(backup_subdir, tier.to_s)
        count = begin
          backup_glob(tier_dir).size
        rescue StandardError
          0
        end
        retained_counts[tier] = count
      end

      return if config.quiet

      puts "Retention for #{File.basename(dir)}: " \
           "#{retained_counts[:hourly]} hourly, #{retained_counts[:daily]} daily, " \
           "#{retained_counts[:weekly]} weekly, #{retained_counts[:monthly]} monthly, " \
           "#{retained_counts[:yearly]} yearly"
    end

    def collect_app_directories
      debug '=== Collecting app directories ==='
      debug "PARENT_DIR: #{config.parent_dir}"
      debug "SOURCE_DIRECTORIES: #{config.source_directories.join(', ')}"

      app_dirs = []
      config.source_directories.each do |src_dir|
        source_path = File.join(config.parent_dir, src_dir)
        debug "Checking source path: #{source_path}"

        unless File.directory?(source_path)
          debug '  Source path does not exist or is not a directory'
          next
        end

        Dir.foreach(source_path) do |entry|
          next if ['.', '..'].include?(entry)

          app_path = File.join(source_path, entry)
          if File.directory?(app_path)
            env_file = File.join(app_path, '.env')
            has_env = File.exist?(env_file)
            debug "  Found app directory: #{app_path} (has .env: #{has_env})"
            app_dirs << app_path
          end
        end
      end

      debug "Total app directories found: #{app_dirs.size}"
      app_dirs
    end

    def run_backup_cycle
      debug '=============================================='
      debug '=== Starting backup cycle ==='
      debug '=============================================='
      debug "DEST_DIR: #{config.dest_dir}"
      debug 'Retention settings:'
      debug "  Hourly:  #{config.retain_hourly}"
      debug "  Daily:   #{config.retain_daily}"
      debug "  Weekly:  #{config.retain_weekly}"
      debug "  Monthly: #{config.retain_monthly}"
      debug "  Yearly:  #{config.retain_yearly}"
      debug ''

      all_pids = []
      all_pg_servers = []
      successful_backups = 0
      failed_backups = 0
      processed_apps = []

      app_directories = collect_app_directories

      app_directories.each do |dir|
        result = process_directory(dir)
        all_pids.concat(result[:pids])
        all_pg_servers.concat(result[:pg_servers])
        if result[:pids].any?
          processed_apps << dir
          debug "Added to processed_apps: #{dir}"
        end
      end

      debug ''
      debug '=== Waiting for backup processes to complete ==='
      debug "Total PIDs to wait for: #{all_pids.size}"

      all_pids.each do |pid|
        _pid, status = Process.wait2(pid)
        debug "PID #{pid} exited with status: #{status.exitstatus}"
        if status.exitstatus.zero?
          successful_backups += 1
        else
          failed_backups += 1
        end
      end

      debug ''
      debug '=== Distributing backups to tier directories ==='
      debug "Processed apps to check: #{processed_apps.size}"

      processed_apps.each do |dir|
        app_subdir = File.join(config.dest_dir, File.basename(dir))
        debug "Checking for new backups in: #{app_subdir}"
        debug "Glob patterns: #{backup_glob_patterns(app_subdir).join(', ')}"
        new_backups = backup_glob(app_subdir)
        debug "Files matching glob: #{new_backups.size}"
        new_backups.each { |f| debug "  - #{f}" }
        puts "Looking for backups in #{app_subdir}: found #{new_backups.size} files" unless config.quiet

        if new_backups.empty?
          debug 'No backup files found to distribute!'
          debug "Listing all files in #{app_subdir}:"
          if File.directory?(app_subdir)
            Dir.foreach(app_subdir) do |f|
              debug "  #{f}" unless ['.', '..'].include?(f)
            end
          else
            debug '  Directory does not exist!'
          end
        end

        new_backups.each { |f| distribute_backup_to_tiers(f, app_subdir) }
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
        backup_subdir = File.join(config.dest_dir, 'postgresql')
        FileUtils.mkdir_p(backup_subdir)

        pg_globals_servers.each do |server_info|
          timestamp = Time.now.strftime('%Y%m%d%H%M%S')
          server_id = "#{server_info[:host]}-#{server_info[:port]}"
          backup_file = File.join(backup_subdir, "backup-globals-#{server_id}-#{timestamp}.sql")
          unless config.quiet
            puts "Backing up PostgreSQL globals from #{server_info[:host]}:#{server_info[:port]} to #{backup_file}"
          end

          result = backup_pg_globals(server_info, backup_file)
          case result
          when true
            successful_backups += 1
            compressed_file = compressed_backup_path(backup_file)
            distribute_backup_to_tiers(compressed_file, backup_subdir) if File.exist?(compressed_file)
          when :skipped
            # Permission denied - don't count as success or failure
          else
            failed_backups += 1
          end
        end
      end

      processed_apps.each do |dir|
        cleanup_old_backups(dir)
      end

      cleanup_old_backups(File.join(config.parent_dir, 'postgresql')) if pg_globals_servers.any?

      if successful_backups.positive? || failed_backups.positive?
        summary = "Backup complete: #{successful_backups} succeeded, #{failed_backups} failed"
        puts summary unless config.quiet
        post_to_slack(summary) if failed_backups.zero? && successful_backups.positive?
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

if __FILE__ == $PROGRAM_NAME
  config = BackupService::Config.new

  OptionParser.new do |opts|
    opts.banner = 'Usage: backup.rb [options]'

    opts.on('--quiet', 'Suppress all output') do
      config.quiet = true
    end
  end.parse!

  backup = BackupService::Backup.new(config)
  backup.run
end
