#!/usr/bin/env ruby

require 'fileutils'
require 'open3'
require 'optparse'

require_relative 'backup'

module BackupService
  # Command line companion to backup.rb for managing age encryption:
  # generating an identity, encrypting an existing backup archive in place,
  # and decrypting backups for restore.
  class Crypt
    ENCRYPTED_SUFFIX = '.age'.freeze
    COMPRESSED_SUFFIX = '.bz2'.freeze
    DEFAULT_KEY_PATH = 'backup-identity.key'.freeze

    BANNER = <<~USAGE.freeze
      Usage: backup-crypt.rb <command> [options] [paths...]

      Commands:
        keygen    Generate an age identity and print its public key
        encrypt   Encrypt existing #{COMPRESSED_SUFFIX} backups in place
        decrypt   Decrypt #{COMPRESSED_SUFFIX}#{ENCRYPTED_SUFFIX} backups

      Run "backup-crypt.rb <command> --help" for command specific options.
    USAGE

    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
      @dry_run = false
      @force = false
      @recipients = []
      @recipients_file = nil
      @identity = nil
      @stdout_output = false
      @key_path = DEFAULT_KEY_PATH
    end

    def run(argv)
      case argv.first
      when 'keygen' then keygen(argv.drop(1))
      when 'encrypt' then encrypt(argv.drop(1))
      when 'decrypt' then decrypt(argv.drop(1))
      when nil, '-h', '--help'
        @out.puts BANNER
        0
      else
        @err.puts "Unknown command: #{argv.first}"
        @err.puts BANNER
        1
      end
    rescue OptionParser::ParseError => e
      @err.puts e.message
      1
    end

    def keygen(argv)
      OptionParser.new do |opts|
        opts.banner = 'Usage: backup-crypt.rb keygen [options]'
        opts.on('-o', '--out PATH', "Identity file to write (default: #{DEFAULT_KEY_PATH})") { |v| @key_path = v }
        opts.on('-f', '--force', 'Overwrite an existing identity file') { @force = true }
      end.parse!(argv)

      if File.exist?(@key_path) && !@force
        @err.puts "Refusing to overwrite existing identity: #{@key_path} (use --force)"
        return 1
      end

      unless command_available?('age-keygen')
        @err.puts <<~MESSAGE
          age-keygen was not found on PATH.

          Install age (Alpine: apk add age, macOS: brew install age) or generate
          the identity on another machine with:

            age-keygen -o #{@key_path}

          Then set BACKUP_ENCRYPTION_RECIPIENTS to the public key it prints.
        MESSAGE
        return 1
      end

      _stdout, stderr, status = Open3.capture3('age-keygen', '-o', @key_path)
      unless status.success?
        @err.puts "age-keygen failed: #{stderr.strip}"
        return 1
      end

      File.chmod(0600, @key_path)
      public_key = extract_public_key(@key_path) || stderr[/age1[0-9a-z]{58}/]

      @out.puts "Identity written to #{@key_path} (mode 0600)"
      @out.puts "Public key: #{public_key}" if public_key
      @out.puts
      @out.puts 'Configure the backup service with:'
      @out.puts "  BACKUP_ENCRYPTION_RECIPIENTS=#{public_key}" if public_key
      @out.puts
      @out.puts 'Store the identity file offline and off the backup server. It is the only'
      @out.puts 'way to decrypt these backups: if you lose it, they are unrecoverable.'
      0
    end

    def encrypt(argv)
      OptionParser.new do |opts|
        opts.banner = 'Usage: backup-crypt.rb encrypt [options] [paths...]'
        opts.on('-r', '--recipient KEY', 'age public key (repeatable)') { |v| @recipients << v }
        opts.on('-R', '--recipients-file FILE', 'File containing one recipient per line') { |v| @recipients_file = v }
        opts.on('-n', '--dry-run', 'Report what would be encrypted without changing anything') { @dry_run = true }
      end.parse!(argv)

      recipients = resolve_recipients
      return 1 unless recipients

      paths = resolve_paths(argv)
      return 1 unless paths

      files, missing = collect_files(paths, COMPRESSED_SUFFIX)
      missing.each { |path| @err.puts "Not found: #{path}" }

      if files.empty?
        @out.puts 'No unencrypted backups found.'
        return missing.empty? ? 0 : 1
      end

      counts = { encrypted: 0, skipped: 0, failed: 0 }
      files.each do |file|
        counts[encrypt_file(file, recipients)] += 1
      end

      @out.puts "Encrypted #{counts[:encrypted]}, skipped #{counts[:skipped]}, failed #{counts[:failed]}"
      @out.puts 'Dry run: no files were changed.' if @dry_run
      (counts[:failed] > 0 || !missing.empty?) ? 1 : 0
    end

    def decrypt(argv)
      OptionParser.new do |opts|
        opts.banner = 'Usage: backup-crypt.rb decrypt [options] [paths...]'
        opts.on('-i', '--identity FILE', 'age identity (private key) file') { |v| @identity = v }
        opts.on('-c', '--stdout', 'Write decrypted output to stdout') { @stdout_output = true }
        opts.on('-f', '--force', 'Overwrite existing decrypted files') { @force = true }
        opts.on('-n', '--dry-run', 'Report what would be decrypted without changing anything') { @dry_run = true }
      end.parse!(argv)

      if @identity.nil? || @identity.empty?
        @err.puts 'An identity file is required: backup-crypt.rb decrypt -i KEYFILE ...'
        return 1
      end

      unless File.file?(@identity)
        @err.puts "Identity file does not exist: #{@identity}"
        return 1
      end

      paths = resolve_paths(argv)
      return 1 unless paths

      files, missing = collect_files(paths, "#{COMPRESSED_SUFFIX}#{ENCRYPTED_SUFFIX}")
      missing.each { |path| @err.puts "Not found: #{path}" }

      if files.empty?
        progress.puts 'No encrypted backups found.'
        return missing.empty? ? 0 : 1
      end

      counts = { decrypted: 0, skipped: 0, failed: 0 }
      files.each do |file|
        counts[decrypt_file(file)] += 1
      end

      progress.puts "Decrypted #{counts[:decrypted]}, skipped #{counts[:skipped]}, failed #{counts[:failed]}"
      progress.puts 'Dry run: no files were changed.' if @dry_run
      (counts[:failed] > 0 || !missing.empty?) ? 1 : 0
    end

    # Encryption is destructive, so the plaintext is only removed after age
    # exits cleanly and the output is confirmed to be a real age file.
    def encrypt_file(file, recipients)
      if file.end_with?(ENCRYPTED_SUFFIX)
        @out.puts "Skipping already encrypted file: #{file}"
        return :skipped
      end

      output_file = "#{file}#{ENCRYPTED_SUFFIX}"
      if File.exist?(output_file)
        @out.puts "Skipping #{file}: #{File.basename(output_file)} already exists"
        return :skipped
      end

      if @dry_run
        @out.puts "Would encrypt #{file} -> #{output_file}"
        return :skipped
      end

      temp_file = "#{output_file}.part"
      command = ['age'] + recipients.flat_map { |r| ['-r', r] } + ['-o', temp_file, file]

      begin
        _stdout, stderr, status = Open3.capture3(*command)

        unless status.success?
          return fail_encrypt(file, temp_file, stderr.strip)
        end

        unless BackupService.age_file?(temp_file)
          return fail_encrypt(file, temp_file, 'output is not a valid age file')
        end

        mtime = File.mtime(file)
        atime = File.atime(file)
        File.rename(temp_file, output_file)
        File.utime(atime, mtime, output_file)
        File.delete(file)
        @out.puts "Encrypted #{file} -> #{output_file}"
        :encrypted
      rescue StandardError => e
        fail_encrypt(file, temp_file, e.message)
      end
    end

    def decrypt_file(file)
      unless file.end_with?(ENCRYPTED_SUFFIX)
        progress.puts "Skipping non-encrypted file: #{file}"
        return :skipped
      end

      if @stdout_output
        return :skipped if @dry_run
        success = system('age', '-d', '-i', @identity, file)
        return success ? :decrypted : :failed
      end

      output_file = file[0...-ENCRYPTED_SUFFIX.length]
      if File.exist?(output_file) && !@force
        progress.puts "Skipping #{file}: #{File.basename(output_file)} already exists (use --force)"
        return :skipped
      end

      if @dry_run
        progress.puts "Would decrypt #{file} -> #{output_file}"
        return :skipped
      end

      temp_file = "#{output_file}.part"

      begin
        _stdout, stderr, status = Open3.capture3('age', '-d', '-i', @identity, '-o', temp_file, file)

        unless status.success?
          File.delete(temp_file) if File.exist?(temp_file)
          @err.puts "Failed to decrypt #{file}: #{stderr.strip}"
          return :failed
        end

        File.rename(temp_file, output_file)
        progress.puts "Decrypted #{file} -> #{output_file}"
        :decrypted
      rescue StandardError => e
        File.delete(temp_file) if File.exist?(temp_file)
        @err.puts "Failed to decrypt #{file}: #{e.message}"
        :failed
      end
    end

    private

    # In --stdout mode the decrypted backup owns stdout, so status messages
    # have to go to stderr to avoid corrupting a pipeline.
    def progress
      @stdout_output ? @err : @out
    end

    def fail_encrypt(file, temp_file, reason)
      File.delete(temp_file) if File.exist?(temp_file)
      @err.puts "Failed to encrypt #{file}: #{reason}"
      :failed
    end

    def resolve_recipients
      recipients = @recipients.flat_map { |value| BackupService.parse_recipient_list(value) }

      if @recipients_file && !@recipients_file.empty?
        unless File.file?(@recipients_file)
          @err.puts "Recipients file does not exist: #{@recipients_file}"
          return nil
        end
        recipients += BackupService.read_recipients_file(@recipients_file)
      end

      if recipients.empty?
        recipients = BackupService.parse_recipient_list(ENV['BACKUP_ENCRYPTION_RECIPIENTS'])
      end

      recipients = recipients.uniq

      if recipients.empty?
        @err.puts 'No recipients given. Use --recipient, --recipients-file, or set BACKUP_ENCRYPTION_RECIPIENTS.'
        return nil
      end

      invalid = recipients.reject { |r| BackupService.valid_age_recipient?(r) }
      unless invalid.empty?
        invalid.each { |r| @err.puts "Invalid age recipient (expected age1... or an SSH public key): #{r}" }
        return nil
      end

      recipients
    end

    def resolve_paths(paths)
      return paths unless paths.empty?

      dest_dir = ENV['DEST_DIR']
      if dest_dir.nil? || dest_dir.empty?
        @err.puts 'No paths given and DEST_DIR is not set.'
        return nil
      end

      progress.puts "No paths given, using DEST_DIR: #{dest_dir}"
      [dest_dir]
    end

    def collect_files(paths, suffix)
      files = []
      missing = []

      paths.each do |path|
        if File.directory?(path)
          files.concat(Dir.glob(File.join(path, '**', "*#{suffix}")))
        elsif File.file?(path)
          files << path
        else
          missing << path
        end
      end

      [files.uniq.sort, missing]
    end

    def extract_public_key(path)
      File.readlines(path).each do |line|
        return $1 if line =~ /public key:\s*(\S+)/i
      end
      nil
    rescue StandardError
      nil
    end

    def command_available?(name)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, name))
      end
    end
  end
end

if __FILE__ == $0
  exit(BackupService::Crypt.new.run(ARGV))
end
