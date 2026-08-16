require 'spec_helper'

RSpec.describe BackupService do
  let(:config) { create_test_config }
  let(:backup) { BackupService::Backup.new(config) }

  describe BackupService::Config do
    describe '#validate!' do
      it 'returns error when SOURCE_DIRECTORIES is empty' do
        config = described_class.new
        config.source_directories = []
        config.dest_dir = '/test/dest'

        errors = config.validate!
        expect(errors).to include('SOURCE_DIRECTORIES environment variable is not set')
      end

      it 'returns error when DEST_DIR is nil' do
        config = described_class.new
        config.source_directories = ['apps']
        config.dest_dir = nil

        errors = config.validate!
        expect(errors).to include('DEST_DIR environment variable is not set')
      end

      it 'returns error when DEST_DIR is empty' do
        config = described_class.new
        config.source_directories = ['apps']
        config.dest_dir = ''

        errors = config.validate!
        expect(errors).to include('DEST_DIR environment variable is not set')
      end

      it 'returns error when source directory does not exist' do
        config = described_class.new
        config.parent_dir = '/opt'
        config.source_directories = ['nonexistent']
        config.dest_dir = '/test/dest'

        errors = config.validate!
        expect(errors).to include('Source directory does not exist: /opt/nonexistent')
      end

      it 'returns empty array when configuration is valid' do
        config = described_class.new
        config.parent_dir = '/tmp'
        config.source_directories = ['.']
        config.dest_dir = '/tmp'

        errors = config.validate!
        expect(errors).to be_empty
      end
    end

    describe '#parse_source_directories' do
      let(:config) { described_class.new }

      it 'parses comma-separated values' do
        result = config.parse_source_directories('apps,experiments,local')
        expect(result).to eq(%w[apps experiments local])
      end

      it 'trims whitespace' do
        result = config.parse_source_directories('apps, experiments , local')
        expect(result).to eq(%w[apps experiments local])
      end

      it 'returns empty array for nil' do
        result = config.parse_source_directories(nil)
        expect(result).to eq([])
      end

      it 'returns empty array for empty string' do
        result = config.parse_source_directories('')
        expect(result).to eq([])
      end
    end

    describe 'encryption recipients' do
      let(:config) do
        config = described_class.new
        config.parent_dir = '/tmp'
        config.source_directories = ['.']
        config.dest_dir = '/tmp'
        config.encryption_recipients = []
        config.encryption_recipients_file = nil
        config
      end

      it 'is disabled when no recipients are configured' do
        expect(config.encryption_enabled?).to be false
        expect(config.validate!).to be_empty
      end

      it 'is enabled when a recipient is configured' do
        config.encryption_recipients = [TEST_AGE_RECIPIENT]

        expect(config.encryption_enabled?).to be true
        expect(config.validate!).to be_empty
      end

      it 'parses a comma-separated recipient list' do
        result = BackupService.parse_recipient_list("#{TEST_AGE_RECIPIENT}, #{TEST_AGE_RECIPIENT_2}")

        expect(result).to eq([TEST_AGE_RECIPIENT, TEST_AGE_RECIPIENT_2])
      end

      it 'returns an empty recipient list for nil and blank values' do
        expect(BackupService.parse_recipient_list(nil)).to eq([])
        expect(BackupService.parse_recipient_list('   ')).to eq([])
      end

      it 'accepts SSH public keys as recipients' do
        expect(BackupService.valid_age_recipient?('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user@host')).to be true
      end

      it 'rejects a malformed recipient' do
        config.encryption_recipients = ['not-a-key']

        errors = config.validate!
        expect(errors).to include(/Invalid age recipient/)
      end

      it 'rejects a recipient that is too short' do
        expect(BackupService.valid_age_recipient?('age1short')).to be false
      end

      it 'rejects a recipient with trailing junk' do
        expect(BackupService.valid_age_recipient?("#{TEST_AGE_RECIPIENT}extra")).to be false
      end

      it 'rejects an age identity used where a public key belongs' do
        expect(BackupService.valid_age_recipient?('AGE-SECRET-KEY-1QQPQY')).to be false
      end

      context 'with a recipients file' do
        include FakeFS::SpecHelpers

        before { FileUtils.mkdir_p('/tmp') }

        it 'merges recipients from the file' do
          File.write('/tmp/recipients.txt', "# team keys\n#{TEST_AGE_RECIPIENT_2}\n\n")
          config.encryption_recipients = [TEST_AGE_RECIPIENT]
          config.encryption_recipients_file = '/tmp/recipients.txt'

          expect(config.validate!).to be_empty
          expect(config.encryption_recipients).to eq([TEST_AGE_RECIPIENT, TEST_AGE_RECIPIENT_2])
        end

        it 'deduplicates recipients present in both sources' do
          File.write('/tmp/recipients.txt', "#{TEST_AGE_RECIPIENT}\n")
          config.encryption_recipients = [TEST_AGE_RECIPIENT]
          config.encryption_recipients_file = '/tmp/recipients.txt'

          config.validate!
          expect(config.encryption_recipients).to eq([TEST_AGE_RECIPIENT])
        end

        it 'returns an error when the file does not exist' do
          config.encryption_recipients_file = '/tmp/missing.txt'

          expect(config.validate!).to include(/does not exist/)
        end

        it 'returns an error when the file has no recipients' do
          File.write('/tmp/empty.txt', "# only a comment\n")
          config.encryption_recipients_file = '/tmp/empty.txt'

          expect(config.validate!).to include(/contains no recipients/)
        end
      end
    end
  end

  describe BackupService::Backup do
    describe '#build_backup_command' do
      context 'PostgreSQL URLs' do
        it 'builds correct command for standard URL' do
          url = 'postgresql://user:password@localhost:5432/mydb'
          command = backup.build_backup_command(url, '/backup/test.sql')

          expect(command).to include('PGPASSWORD=password')
          expect(command).to include('pg_dump')
          expect(command).to include('-h localhost')
          expect(command).to include('-p 5432')
          expect(command).to include('-U user')
          expect(command).to include('-d mydb')
          expect(command).to include('-f /backup/test.sql')
        end

        it 'escapes special characters in password' do
          url = "postgresql://user:p'ss$word@localhost:5432/mydb"
          command = backup.build_backup_command(url, '/backup/test.sql')

          expect(command).to include("PGPASSWORD=p\\'ss\\$word")
        end

        it 'escapes spaces in file paths' do
          url = 'postgresql://user:pass@localhost:5432/mydb'
          command = backup.build_backup_command(url, '/backup/my backup.sql')

          expect(command).to include('/backup/my\\ backup.sql')
        end
      end

      context 'MySQL URLs' do
        it 'builds correct command for standard URL' do
          url = 'mysql://user:password@localhost:3306/mydb'
          command = backup.build_backup_command(url, '/backup/test.sql')

          expect(command).to include('mysqldump')
          expect(command).to include('-h localhost')
          expect(command).to include('-P 3306')
          expect(command).to include('-u user')
          expect(command).to include('-ppassword')
          expect(command).to include('mydb')
        end

        it 'escapes special characters in password' do
          url = "mysql://user:p'ss$word@localhost:3306/mydb"
          command = backup.build_backup_command(url, '/backup/test.sql')

          expect(command).to include("-pp\\'ss\\$word")
        end
      end

      context 'SQLite URLs' do
        it 'builds correct command for absolute path' do
          url = 'sqlite:///var/data/mydb.db'
          command = backup.build_backup_command(url, '/backup/test.sql')

          expect(command).to include('sqlite3')
          expect(command).to include('/var/data/mydb.db')
          expect(command).to include('.dump')
        end

        it 'escapes paths with spaces' do
          url = 'sqlite:///var/my data/mydb.db'
          command = backup.build_backup_command(url, '/backup/test.sql')

          expect(command).to include('/var/my\\ data/mydb.db')
        end
      end

      context 'Qdrant URLs' do
        it 'returns nil for Qdrant (handled separately)' do
          url = 'qdrant://localhost:6333/my_collection'
          command = backup.build_backup_command(url, '/backup/test.snapshot')

          expect(command).to be_nil
        end
      end

      context 'Invalid URLs' do
        it 'returns nil for unsupported schemes' do
          url = 'mongodb://user:pass@localhost:27017/mydb'
          command = backup.build_backup_command(url, '/backup/test.bson')

          expect(command).to be_nil
        end

        it 'returns nil for malformed URLs' do
          url = 'not-a-valid-url'
          command = backup.build_backup_command(url, '/backup/test.sql')

          expect(command).to be_nil
        end
      end
    end

    describe '#extract_pg_server_info' do
      it 'extracts server info from PostgreSQL URL' do
        url = 'postgresql://user:password@localhost:5432/mydb'
        info = backup.extract_pg_server_info(url)

        expect(info).to eq({ user: 'user', password: 'password', host: 'localhost', port: '5432' })
      end

      it 'returns nil for non-PostgreSQL URLs' do
        url = 'mysql://user:pass@localhost:3306/mydb'
        info = backup.extract_pg_server_info(url)

        expect(info).to be_nil
      end
    end

    describe '#build_pg_dumpall_command' do
      it 'builds correct pg_dumpall command' do
        server_info = { user: 'admin', password: 'secret', host: 'pghost', port: '5432' }
        command = backup.build_pg_dumpall_command(server_info, '/backup/globals.sql')

        expect(command).to include('PGPASSWORD=secret')
        expect(command).to include('pg_dumpall')
        expect(command).to include('-h pghost')
        expect(command).to include('-p 5432')
        expect(command).to include('-U admin')
        expect(command).to include('--globals-only')
        expect(command).to include('> /backup/globals.sql')
      end

      it 'escapes special characters in password' do
        server_info = { user: 'admin', password: "p'ss$word", host: 'pghost', port: '5432' }
        command = backup.build_pg_dumpall_command(server_info, '/backup/globals.sql')

        expect(command).to include("PGPASSWORD=p\\'ss\\$word")
      end
    end

    describe '#backup_pg_globals' do
      let(:config) { create_test_config(quiet: true) }
      let(:backup) { described_class.new(config) }
      let(:server_info) { { user: 'admin', password: 'secret', host: 'localhost', port: '5432' } }

      # $? is thread-global and cannot be stubbed (Process::Status is frozen),
      # so the fake backtick runs a real trivial command to set it.
      def stub_backtick(backup, output, exit_status)
        allow(backup).to receive(:`) do |_command|
          system(exit_status.zero? ? 'true' : 'false')
          output
        end
      end

      it 'returns :skipped and deletes file on permission denied' do
        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'globals.sql')

          stub_backtick(backup, 'pg_dumpall: error: permission denied for table pg_authid', 1)

          result = backup.backup_pg_globals(server_info, backup_file)

          expect(result).to eq(:skipped)
          expect(File.exist?(backup_file)).to be false
        end
      end

      it 'returns false on other errors' do
        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'globals.sql')

          stub_backtick(backup, 'connection refused', 1)
          allow(backup).to receive(:post_to_slack)

          result = backup.backup_pg_globals(server_info, backup_file)

          expect(result).to be(false)
          expect(backup).to have_received(:post_to_slack)
        end
      end

      it 'compresses and encrypts a successful globals dump' do
        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'globals.sql')
          File.write(backup_file, 'CREATE ROLE admin;')

          stub_backtick(backup, '', 0)
          allow(backup).to receive(:compress_and_encrypt_file).and_return(true)

          expect(backup.backup_pg_globals(server_info, backup_file)).to be true
          expect(backup).to have_received(:compress_and_encrypt_file).with(backup_file)
        end
      end

      it 'reports failure when the globals dump cannot be encrypted' do
        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'globals.sql')
          File.write(backup_file, 'CREATE ROLE admin;')

          stub_backtick(backup, '', 0)
          allow(backup).to receive(:compress_and_encrypt_file).and_return(false)

          expect(backup.backup_pg_globals(server_info, backup_file)).to be false
        end
      end
    end

    describe '#generate_backup_filename' do
      let(:timestamp) { '20240115120000' }

      it 'generates .sql filename for PostgreSQL' do
        url = 'postgresql://user:pass@localhost:5432/mydb'
        filename = backup.generate_backup_filename(url, timestamp)

        expect(filename).to eq('backup-mydb-20240115120000.sql')
      end

      it 'generates .sql filename for MySQL' do
        url = 'mysql://user:pass@localhost:3306/mydb'
        filename = backup.generate_backup_filename(url, timestamp)

        expect(filename).to eq('backup-mydb-20240115120000.sql')
      end

      it 'generates .sql filename for SQLite using basename' do
        url = 'sqlite:///var/data/application.db'
        filename = backup.generate_backup_filename(url, timestamp)

        expect(filename).to eq('backup-application-20240115120000.sql')
      end

      it 'generates .snapshot filename for Qdrant' do
        url = 'qdrant://localhost:6333/embeddings'
        filename = backup.generate_backup_filename(url, timestamp)

        expect(filename).to eq('backup-embeddings-20240115120000.snapshot')
      end

      it 'generates .snapshot filename for Qdrant with API key' do
        url = 'qdrant://my-api-key@localhost:6333/embeddings'
        filename = backup.generate_backup_filename(url, timestamp)

        expect(filename).to eq('backup-embeddings-20240115120000.snapshot')
      end

      it 'returns nil for unsupported URLs' do
        url = 'mongodb://user:pass@localhost:27017/mydb'
        filename = backup.generate_backup_filename(url, timestamp)

        expect(filename).to be_nil
      end
    end

    describe '#parse_backup_timestamp' do
      it 'parses timestamp from SQL backup filename' do
        filename = 'backup-mydb-20240115143022.sql'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to eq(Time.new(2024, 1, 15, 14, 30, 22))
      end

      it 'parses timestamp from compressed SQL backup' do
        filename = 'backup-mydb-20240115143022.sql.bz2'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to eq(Time.new(2024, 1, 15, 14, 30, 22))
      end

      it 'parses timestamp from snapshot backup filename' do
        filename = 'backup-embeddings-20240115143022.snapshot'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to eq(Time.new(2024, 1, 15, 14, 30, 22))
      end

      it 'parses timestamp from compressed snapshot backup' do
        filename = 'backup-embeddings-20240115143022.snapshot.bz2'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to eq(Time.new(2024, 1, 15, 14, 30, 22))
      end

      it 'handles database names with dashes' do
        filename = 'backup-my-app-db-20240115143022.sql.bz2'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to eq(Time.new(2024, 1, 15, 14, 30, 22))
      end

      it 'returns nil for invalid filename format' do
        filename = 'invalid-backup-file.sql'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to be_nil
      end

      it 'returns nil for missing timestamp' do
        filename = 'backup-mydb.sql.bz2'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to be_nil
      end

      it 'parses timestamp from an encrypted backup' do
        filename = 'backup-mydb-20240115143022.sql.bz2.age'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to eq(Time.new(2024, 1, 15, 14, 30, 22))
      end

      it 'parses timestamp from an encrypted snapshot backup' do
        filename = 'backup-embeddings-20240115143022.snapshot.bz2.age'
        timestamp = backup.parse_backup_timestamp(filename)

        expect(timestamp).to eq(Time.new(2024, 1, 15, 14, 30, 22))
      end
    end

    describe '#extract_dbname' do
      it 'extracts database name from SQL backup' do
        filename = 'backup-mydb-20240115143022.sql'
        dbname = backup.extract_dbname(filename)

        expect(dbname).to eq('mydb')
      end

      it 'extracts database name from compressed SQL backup' do
        filename = 'backup-mydb-20240115143022.sql.bz2'
        dbname = backup.extract_dbname(filename)

        expect(dbname).to eq('mydb')
      end

      it 'extracts collection name from snapshot backup' do
        filename = 'backup-embeddings-20240115143022.snapshot.bz2'
        dbname = backup.extract_dbname(filename)

        expect(dbname).to eq('embeddings')
      end

      it 'handles database names with dashes' do
        filename = 'backup-my-app-db-20240115143022.sql.bz2'
        dbname = backup.extract_dbname(filename)

        expect(dbname).to eq('my-app-db')
      end

      it 'returns nil for invalid filename format' do
        filename = 'invalid-backup-file.sql'
        dbname = backup.extract_dbname(filename)

        expect(dbname).to be_nil
      end

      it 'extracts database name from an encrypted backup' do
        filename = 'backup-mydb-20240115143022.sql.bz2.age'
        dbname = backup.extract_dbname(filename)

        expect(dbname).to eq('mydb')
      end

      it 'handles dashed database names in an encrypted backup' do
        filename = 'backup-my-app-db-20240115143022.sql.bz2.age'
        dbname = backup.extract_dbname(filename)

        expect(dbname).to eq('my-app-db')
      end
    end

    describe '#backup_glob' do
      include FakeFS::SpecHelpers

      let(:config) { create_test_config(dest_dir: '/test/dest') }
      let(:backup) { described_class.new(config) }

      before do
        FileUtils.mkdir_p('/test/dest/myapp')
        File.write('/test/dest/myapp/backup-db-20240115120000.sql.bz2', 'plain')
        File.write('/test/dest/myapp/backup-db-20240115130000.sql.bz2.age', 'encrypted')
        File.write('/test/dest/myapp/backup-other-20240115140000.snapshot.bz2.age', 'encrypted')
        File.write('/test/dest/myapp/backup-db-20240115150000.sql.bz2.part', 'partial')
        File.write('/test/dest/myapp/notes.txt', 'unrelated')
      end

      it 'finds both encrypted and unencrypted backups' do
        files = backup.backup_glob('/test/dest/myapp').map { |f| File.basename(f) }

        expect(files).to contain_exactly(
          'backup-db-20240115120000.sql.bz2',
          'backup-db-20240115130000.sql.bz2.age',
          'backup-other-20240115140000.snapshot.bz2.age'
        )
      end

      it 'ignores partial files from an interrupted run' do
        files = backup.backup_glob('/test/dest/myapp')

        expect(files.none? { |f| f.end_with?('.part') }).to be true
      end

      it 'filters by database name' do
        files = backup.backup_glob('/test/dest/myapp', 'db').map { |f| File.basename(f) }

        expect(files).to contain_exactly(
          'backup-db-20240115120000.sql.bz2',
          'backup-db-20240115130000.sql.bz2.age'
        )
      end
    end

    describe '#cleanup_tier with mixed encrypted and plaintext backups' do
      include FakeFS::SpecHelpers

      let(:config) { create_test_config(dest_dir: '/test/dest', retain_hourly: 2) }
      let(:backup) { described_class.new(config) }
      let(:tier_dir) { '/test/dest/myapp/hourly' }

      before { FileUtils.mkdir_p(tier_dir) }

      it 'keeps the encrypted copy when both exist for the same backup' do
        plaintext = "#{tier_dir}/backup-db-20240115120000.sql.bz2"
        encrypted = "#{plaintext}.age"
        File.write(plaintext, 'plain')
        File.write(encrypted, 'encrypted')

        backup.cleanup_tier(tier_dir, :hourly)

        expect(File.exist?(encrypted)).to be true
        expect(File.exist?(plaintext)).to be false
      end

      it 'applies retention across encrypted and plaintext backups together' do
        File.write("#{tier_dir}/backup-db-20240115100000.sql.bz2", 'oldest')
        File.write("#{tier_dir}/backup-db-20240115110000.sql.bz2.age", 'middle')
        File.write("#{tier_dir}/backup-db-20240115120000.sql.bz2.age", 'newest')

        backup.cleanup_tier(tier_dir, :hourly)

        expect(File.exist?("#{tier_dir}/backup-db-20240115120000.sql.bz2.age")).to be true
        expect(File.exist?("#{tier_dir}/backup-db-20240115110000.sql.bz2.age")).to be true
        expect(File.exist?("#{tier_dir}/backup-db-20240115100000.sql.bz2")).to be false
      end
    end

    describe '#pipeline_stages' do
      it 'compresses only when there are no recipients' do
        stages = backup.pipeline_stages('/tmp/backup.sql', [])

        expect(stages).to eq([['bzip2', '-c', '/tmp/backup.sql']])
      end

      it 'pipes through age for a single recipient' do
        stages = backup.pipeline_stages('/tmp/backup.sql', [TEST_AGE_RECIPIENT])

        expect(stages).to eq([
                               ['bzip2', '-c', '/tmp/backup.sql'],
                               ['age', '-r', TEST_AGE_RECIPIENT]
                             ])
      end

      it 'passes every recipient to age' do
        stages = backup.pipeline_stages('/tmp/backup.sql', [TEST_AGE_RECIPIENT, TEST_AGE_RECIPIENT_2])

        expect(stages.last).to eq([
                                    'age', '-r', TEST_AGE_RECIPIENT, '-r', TEST_AGE_RECIPIENT_2
                                  ])
      end

      it 'builds arguments as an array so filenames are never shell-interpreted' do
        stages = backup.pipeline_stages('/tmp/back up; rm -rf /.sql', [TEST_AGE_RECIPIENT])

        expect(stages.first).to eq(['bzip2', '-c', '/tmp/back up; rm -rf /.sql'])
      end
    end

    describe '#compressed_backup_path' do
      it 'appends .bz2 when encryption is disabled' do
        config = create_test_config
        backup = described_class.new(config)

        expect(backup.compressed_backup_path('/tmp/backup.sql')).to eq('/tmp/backup.sql.bz2')
      end

      it 'appends .bz2.age when encryption is enabled' do
        config = create_test_config(encryption_recipients: [TEST_AGE_RECIPIENT])
        backup = described_class.new(config)

        expect(backup.compressed_backup_path('/tmp/backup.sql')).to eq('/tmp/backup.sql.bz2.age')
      end
    end

    describe '#compress_and_encrypt_file' do
      around do |example|
        Dir.mktmpdir do |dir|
          @tmpdir = dir
          example.run
        end
      end

      let(:source) { File.join(@tmpdir, 'backup-db-20240115120000.sql') }

      before { File.write(source, 'SELECT 1;' * 100) }

      context 'without encryption' do
        let(:config) { create_test_config(quiet: true) }
        let(:backup) { described_class.new(config) }

        it 'compresses and removes the plaintext dump' do
          expect(backup.compress_and_encrypt_file(source)).to be true

          expect(File.exist?("#{source}.bz2")).to be true
          expect(File.exist?(source)).to be false
        end

        it 'leaves no partial file behind' do
          backup.compress_and_encrypt_file(source)

          expect(Dir.glob(File.join(@tmpdir, '*.part'))).to be_empty
        end
      end

      context 'when a pipeline stage fails' do
        let(:config) { create_test_config(quiet: true) }
        let(:backup) { described_class.new(config) }

        before do
          allow(backup).to receive(:pipeline_stages).and_return([['false']])
          allow(backup).to receive(:post_to_slack)
        end

        it 'returns false' do
          expect(backup.compress_and_encrypt_file(source)).to be false
        end

        it 'removes the plaintext dump so it cannot linger unencrypted' do
          backup.compress_and_encrypt_file(source)

          expect(File.exist?(source)).to be false
        end

        it 'removes the partial output' do
          backup.compress_and_encrypt_file(source)

          expect(Dir.glob(File.join(@tmpdir, '*.part'))).to be_empty
          expect(File.exist?("#{source}.bz2")).to be false
        end

        it 'reports the failure to Slack' do
          backup.compress_and_encrypt_file(source)

          expect(backup).to have_received(:post_to_slack).with(/Error compressing file/)
        end
      end

      context 'when the encryption tool is missing' do
        let(:config) { create_test_config(quiet: true, encryption_recipients: [TEST_AGE_RECIPIENT]) }
        let(:backup) { described_class.new(config) }

        before do
          allow(backup).to receive(:pipeline_stages).and_return([['bzip2', '-c', source],
                                                                 ['definitely-not-a-real-binary']])
          allow(backup).to receive(:post_to_slack)
        end

        it 'fails closed rather than writing an unencrypted backup' do
          expect(backup.compress_and_encrypt_file(source)).to be false

          expect(File.exist?(source)).to be false
          expect(File.exist?("#{source}.bz2")).to be false
          expect(File.exist?("#{source}.bz2.age")).to be false
          expect(Dir.glob(File.join(@tmpdir, '*.part'))).to be_empty
        end
      end

      context 'when the output is not a valid age file' do
        let(:config) { create_test_config(quiet: true, encryption_recipients: [TEST_AGE_RECIPIENT]) }
        let(:backup) { described_class.new(config) }

        before do
          # cat succeeds but produces bzip2 output rather than an age file
          allow(backup).to receive(:pipeline_stages).and_return([['bzip2', '-c', source], ['cat']])
          allow(backup).to receive(:post_to_slack)
        end

        it 'rejects the result' do
          expect(backup.compress_and_encrypt_file(source)).to be false
          expect(File.exist?("#{source}.bz2.age")).to be false
        end

        it 'explains why in the error' do
          backup.compress_and_encrypt_file(source)

          expect(backup).to have_received(:post_to_slack).with(/not a valid age file/)
        end
      end
    end

    describe '.age_file?' do
      around do |example|
        Dir.mktmpdir do |dir|
          @tmpdir = dir
          example.run
        end
      end

      it 'recognises an age file by its version header' do
        path = File.join(@tmpdir, 'encrypted')
        File.write(path, "age-encryption.org/v1\n-> X25519 abc\n")

        expect(BackupService.age_file?(path)).to be true
      end

      it 'rejects a file with other contents' do
        path = File.join(@tmpdir, 'plain')
        File.write(path, 'BZh91AY&SY')

        expect(BackupService.age_file?(path)).to be false
      end

      it 'rejects an empty file' do
        path = File.join(@tmpdir, 'empty')
        File.write(path, '')

        expect(BackupService.age_file?(path)).to be false
      end

      it 'rejects a missing file' do
        expect(BackupService.age_file?(File.join(@tmpdir, 'nope'))).to be false
      end
    end

    describe '#parse_database_urls' do
      include FakeFS::SpecHelpers

      before do
        FileUtils.mkdir_p('/test/app')
      end

      it 'parses single URL without quotes' do
        File.write('/test/app/.env', "BACKUP_DATABASE_URLS=postgresql://user:pass@host:5432/db\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq(['postgresql://user:pass@host:5432/db'])
      end

      it 'parses single URL with double quotes' do
        File.write('/test/app/.env', "BACKUP_DATABASE_URLS=\"postgresql://user:pass@host:5432/db\"\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq(['postgresql://user:pass@host:5432/db'])
      end

      it 'parses single URL with single quotes' do
        File.write('/test/app/.env', "BACKUP_DATABASE_URLS='postgresql://user:pass@host:5432/db'\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq(['postgresql://user:pass@host:5432/db'])
      end

      it 'parses multiple comma-separated URLs' do
        File.write('/test/app/.env', "BACKUP_DATABASE_URLS=postgresql://u:p@h:5432/db1,mysql://u:p@h:3306/db2\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq([
                             'postgresql://u:p@h:5432/db1',
                             'mysql://u:p@h:3306/db2'
                           ])
      end

      it 'parses multiple URLs with quotes around each' do
        File.write('/test/app/.env',
                   "BACKUP_DATABASE_URLS=\"postgresql://u:p@h:5432/db1\",\"mysql://u:p@h:3306/db2\"\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq([
                             'postgresql://u:p@h:5432/db1',
                             'mysql://u:p@h:3306/db2'
                           ])
      end

      it 'returns empty array when BACKUP_DATABASE_URLS is not present' do
        File.write('/test/app/.env', "OTHER_VAR=value\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq([])
      end

      it 'handles URLs with spaces after commas' do
        File.write('/test/app/.env', "BACKUP_DATABASE_URLS=postgresql://u:p@h:5432/db1, mysql://u:p@h:3306/db2\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq([
                             'postgresql://u:p@h:5432/db1',
                             'mysql://u:p@h:3306/db2'
                           ])
      end

      it 'parses per-URL quoted URLs with commas inside a database name' do
        File.write('/test/app/.env', "BACKUP_DATABASE_URLS=\"postgresql://u:p@h:5432/my,db\"\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq(['postgresql://u:p@h:5432/my,db'])
      end

      it 'parses a whole-value quoted list of multiple URLs' do
        File.write('/test/app/.env',
                   "BACKUP_DATABASE_URLS=\"postgresql://u:p@h:5432/db1,mysql://u:p@h:3306/db2\"\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq([
                             'postgresql://u:p@h:5432/db1',
                             'mysql://u:p@h:3306/db2'
                           ])
      end

      it 'ignores commented-out BACKUP_DATABASE_URLS lines' do
        File.write('/test/app/.env', "# BACKUP_DATABASE_URLS=postgresql://u:p@h:5432/db\n")

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq([])
      end

      it 'handles other lines in the env file' do
        content = <<~ENV
          DATABASE_URL=postgresql://other:other@host:5432/other
          BACKUP_DATABASE_URLS=postgresql://user:pass@host:5432/db
          ANOTHER_VAR=value
        ENV
        File.write('/test/app/.env', content)

        urls = backup.parse_database_urls('/test/app/.env')

        expect(urls).to eq(['postgresql://user:pass@host:5432/db'])
      end
    end

    describe '#tier_key_for_timestamp' do
      it 'returns correct hourly key' do
        timestamp = Time.new(2024, 1, 15, 14, 30, 22)
        expect(backup.tier_key_for_timestamp(:hourly, timestamp)).to eq('2024-01-15-14')
      end

      it 'returns correct daily key' do
        timestamp = Time.new(2024, 1, 15, 14, 30, 22)
        expect(backup.tier_key_for_timestamp(:daily, timestamp)).to eq('2024-01-15')
      end

      it 'returns correct weekly key' do
        timestamp = Time.new(2024, 1, 15, 14, 30, 22)
        expect(backup.tier_key_for_timestamp(:weekly, timestamp)).to eq('2024-03')
      end

      it 'returns correct monthly key' do
        timestamp = Time.new(2024, 1, 15, 14, 30, 22)
        expect(backup.tier_key_for_timestamp(:monthly, timestamp)).to eq('2024-01')
      end

      it 'returns correct yearly key' do
        timestamp = Time.new(2024, 1, 15, 14, 30, 22)
        expect(backup.tier_key_for_timestamp(:yearly, timestamp)).to eq('2024')
      end
    end

    describe '#distribute_backup_to_tiers' do
      include FakeFS::SpecHelpers

      let(:config) { create_test_config(dest_dir: '/test/dest', quiet: true) }
      let(:backup) { described_class.new(config) }

      before do
        FileUtils.mkdir_p('/test/dest/myapp')
      end

      it 'copies backup to all tier directories' do
        backup_file = '/test/dest/myapp/backup-db-20240115120000.sql.bz2'
        File.write(backup_file, 'backup data')

        backup.distribute_backup_to_tiers(backup_file, '/test/dest/myapp')

        BackupService::Backup::TIERS.each do |tier|
          tier_file = "/test/dest/myapp/#{tier}/backup-db-20240115120000.sql.bz2"
          expect(File.exist?(tier_file)).to be true
        end
      end

      it 'deletes original file after distribution' do
        backup_file = '/test/dest/myapp/backup-db-20240115120000.sql.bz2'
        File.write(backup_file, 'backup data')

        backup.distribute_backup_to_tiers(backup_file, '/test/dest/myapp')

        expect(File.exist?(backup_file)).to be false
      end

      it 'does not overwrite existing file in tier' do
        FileUtils.mkdir_p('/test/dest/myapp/hourly')
        existing_file = '/test/dest/myapp/hourly/backup-db-20240115110000.sql.bz2'
        File.write(existing_file, 'existing backup')

        backup_file = '/test/dest/myapp/backup-db-20240115120000.sql.bz2'
        File.write(backup_file, 'new backup')

        backup.distribute_backup_to_tiers(backup_file, '/test/dest/myapp')

        expect(File.read(existing_file)).to eq('existing backup')
      end

      it 'distributes encrypted backups to all tier directories' do
        backup_file = '/test/dest/myapp/backup-db-20240115120000.sql.bz2.age'
        File.write(backup_file, "#{BackupService::AGE_HEADER}\nencrypted")

        backup.distribute_backup_to_tiers(backup_file, '/test/dest/myapp')

        BackupService::Backup::TIERS.each do |tier|
          tier_file = "/test/dest/myapp/#{tier}/backup-db-20240115120000.sql.bz2.age"
          expect(File.exist?(tier_file)).to be true
        end
      end
    end

    describe '#cleanup_old_backups' do
      include FakeFS::SpecHelpers

      let(:config) do
        create_test_config(
          parent_dir: '/test/parent',
          dest_dir: '/test/dest',
          retain_hourly: 2,
          retain_daily: 1,
          retain_weekly: 1,
          retain_monthly: 1,
          retain_yearly: 1
        )
      end
      let(:backup) { described_class.new(config) }

      before do
        FileUtils.mkdir_p('/test/dest/myapp/hourly')
        FileUtils.mkdir_p('/test/dest/myapp/daily')
      end

      it 'deletes files beyond retention limits in tier directories' do
        files = [
          '/test/dest/myapp/hourly/backup-db-20240115100000.sql.bz2',
          '/test/dest/myapp/hourly/backup-db-20240115110000.sql.bz2',
          '/test/dest/myapp/hourly/backup-db-20240115120000.sql.bz2',
          '/test/dest/myapp/hourly/backup-db-20240115130000.sql.bz2'
        ]
        files.each { |f| FileUtils.touch(f) }

        backup.cleanup_old_backups('/test/parent/myapp')

        expect(File.exist?('/test/dest/myapp/hourly/backup-db-20240115130000.sql.bz2')).to be true
        expect(File.exist?('/test/dest/myapp/hourly/backup-db-20240115120000.sql.bz2')).to be true
      end

      it 'cleans up each tier directory independently' do
        FileUtils.touch('/test/dest/myapp/hourly/backup-db-20240115120000.sql.bz2')
        FileUtils.touch('/test/dest/myapp/daily/backup-db-20240115120000.sql.bz2')

        backup.cleanup_old_backups('/test/parent/myapp')

        expect(File.exist?('/test/dest/myapp/hourly/backup-db-20240115120000.sql.bz2')).to be true
        expect(File.exist?('/test/dest/myapp/daily/backup-db-20240115120000.sql.bz2')).to be true
      end

      it 'handles mixed file types in tier directories' do
        FileUtils.touch('/test/dest/myapp/hourly/backup-db-20240115120000.sql.bz2')
        FileUtils.touch('/test/dest/myapp/hourly/backup-vectors-20240115120000.snapshot.bz2')

        backup.cleanup_old_backups('/test/parent/myapp')

        expect(File.exist?('/test/dest/myapp/hourly/backup-db-20240115120000.sql.bz2')).to be true
        expect(File.exist?('/test/dest/myapp/hourly/backup-vectors-20240115120000.snapshot.bz2')).to be true
      end

      it 'does nothing when backup directory does not exist' do
        expect { backup.cleanup_old_backups('/test/parent/nonexistent') }.not_to raise_error
      end
    end

    describe '#post_to_slack' do
      let(:config) { create_test_config(slack_webhook_url: 'https://hooks.slack.com/services/T00/B00/XXX', quiet: true) }
      let(:backup) { described_class.new(config) }

      it 'sends message to Slack webhook' do
        stub = stub_request(:post, 'https://hooks.slack.com/services/T00/B00/XXX')
               .with(
                 body: { text: 'Test message' }.to_json,
                 headers: { 'Content-Type' => 'application/json' }
               )
               .to_return(status: 200)

        backup.post_to_slack('Test message')

        expect(stub).to have_been_requested
      end

      it 'does nothing when webhook URL is nil' do
        config = create_test_config(slack_webhook_url: nil)
        backup = described_class.new(config)

        expect { backup.post_to_slack('Test message') }.not_to raise_error
        expect(WebMock).not_to have_requested(:post, /slack/)
      end

      it 'does nothing when webhook URL is empty' do
        config = create_test_config(slack_webhook_url: '')
        backup = described_class.new(config)

        expect { backup.post_to_slack('Test message') }.not_to raise_error
        expect(WebMock).not_to have_requested(:post, /slack/)
      end

      it 'handles HTTP errors gracefully' do
        stub_request(:post, 'https://hooks.slack.com/services/T00/B00/XXX')
          .to_return(status: 500, body: 'Internal Server Error')

        expect { backup.post_to_slack('Test message') }.not_to raise_error
      end

      it 'handles connection errors gracefully' do
        stub_request(:post, 'https://hooks.slack.com/services/T00/B00/XXX')
          .to_raise(Errno::ECONNREFUSED)

        expect { backup.post_to_slack('Test message') }.not_to raise_error
      end
    end

    describe '#backup_qdrant' do
      let(:config) { create_test_config(quiet: true) }
      let(:backup) { described_class.new(config) }

      it 'creates snapshot, downloads, and deletes remote snapshot' do
        stub_request(:post, 'http://localhost:6333/collections/my_collection/snapshots')
          .to_return(
            status: 200,
            body: { result: { name: 'snapshot-123.snapshot' } }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:get, 'http://localhost:6333/collections/my_collection/snapshots/snapshot-123.snapshot')
          .to_return(status: 200, body: 'snapshot-data')

        stub_request(:delete, 'http://localhost:6333/collections/my_collection/snapshots/snapshot-123.snapshot')
          .to_return(status: 200)

        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'backup.snapshot')
          result = backup.backup_qdrant('localhost', '6333', 'my_collection', nil, backup_file)

          expect(result).to be true
          expect(File.read(backup_file)).to eq('snapshot-data')
        end
      end

      it 'includes API key header when provided' do
        stub_request(:post, 'http://localhost:6333/collections/my_collection/snapshots')
          .with(headers: { 'api-key' => 'my-secret-key' })
          .to_return(
            status: 200,
            body: { result: { name: 'snapshot-123.snapshot' } }.to_json
          )

        stub_request(:get, 'http://localhost:6333/collections/my_collection/snapshots/snapshot-123.snapshot')
          .with(headers: { 'api-key' => 'my-secret-key' })
          .to_return(status: 200, body: 'data')

        stub_request(:delete, 'http://localhost:6333/collections/my_collection/snapshots/snapshot-123.snapshot')
          .with(headers: { 'api-key' => 'my-secret-key' })
          .to_return(status: 200)

        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'backup.snapshot')
          result = backup.backup_qdrant('localhost', '6333', 'my_collection', 'my-secret-key', backup_file)

          expect(result).to be true
        end
      end

      it 'returns false when snapshot creation fails' do
        stub_request(:post, 'http://localhost:6333/collections/my_collection/snapshots')
          .to_return(status: 500, body: 'Internal Server Error')

        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'backup.snapshot')
          result = backup.backup_qdrant('localhost', '6333', 'my_collection', nil, backup_file)

          expect(result).to be false
        end
      end

      it 'returns false when snapshot name is missing' do
        stub_request(:post, 'http://localhost:6333/collections/my_collection/snapshots')
          .to_return(status: 200, body: { result: {} }.to_json)

        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'backup.snapshot')
          result = backup.backup_qdrant('localhost', '6333', 'my_collection', nil, backup_file)

          expect(result).to be false
        end
      end

      it 'returns false when download fails' do
        stub_request(:post, 'http://localhost:6333/collections/my_collection/snapshots')
          .to_return(
            status: 200,
            body: { result: { name: 'snapshot-123.snapshot' } }.to_json
          )

        stub_request(:get, 'http://localhost:6333/collections/my_collection/snapshots/snapshot-123.snapshot')
          .to_return(status: 404)

        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'backup.snapshot')
          result = backup.backup_qdrant('localhost', '6333', 'my_collection', nil, backup_file)

          expect(result).to be false
        end
      end

      it 'handles connection errors' do
        stub_request(:post, 'http://localhost:6333/collections/my_collection/snapshots')
          .to_raise(Errno::ECONNREFUSED)

        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'backup.snapshot')
          result = backup.backup_qdrant('localhost', '6333', 'my_collection', nil, backup_file)

          expect(result).to be false
        end
      end

      it 'succeeds even when delete fails (warning only)' do
        stub_request(:post, 'http://localhost:6333/collections/my_collection/snapshots')
          .to_return(
            status: 200,
            body: { result: { name: 'snapshot-123.snapshot' } }.to_json
          )

        stub_request(:get, 'http://localhost:6333/collections/my_collection/snapshots/snapshot-123.snapshot')
          .to_return(status: 200, body: 'data')

        stub_request(:delete, 'http://localhost:6333/collections/my_collection/snapshots/snapshot-123.snapshot')
          .to_return(status: 500)

        Dir.mktmpdir do |dir|
          backup_file = File.join(dir, 'backup.snapshot')
          result = backup.backup_qdrant('localhost', '6333', 'my_collection', nil, backup_file)

          expect(result).to be true
        end
      end
    end

    describe '#backup_database' do
      let(:config) { create_test_config(quiet: true) }
      let(:backup) { described_class.new(config) }

      context 'with Qdrant URL' do
        it 'calls backup_qdrant and compress_and_encrypt_file on success' do
          allow(backup).to receive_messages(backup_qdrant: true, compress_and_encrypt_file: true)

          result = backup.backup_database('qdrant://localhost:6333/collection', '/tmp/backup.snapshot')

          expect(result).to be true
          expect(backup).to have_received(:backup_qdrant).with('localhost', '6333', 'collection', nil,
                                                               '/tmp/backup.snapshot')
          expect(backup).to have_received(:compress_and_encrypt_file).with('/tmp/backup.snapshot')
        end

        it 'extracts API key from URL' do
          allow(backup).to receive_messages(backup_qdrant: true, compress_and_encrypt_file: true)

          backup.backup_database('qdrant://my-key@localhost:6333/collection', '/tmp/backup.snapshot')

          expect(backup).to have_received(:backup_qdrant).with('localhost', '6333', 'collection', 'my-key',
                                                               '/tmp/backup.snapshot')
        end

        it 'does not compress on failure' do
          allow(backup).to receive(:backup_qdrant).and_return(false)
          allow(backup).to receive(:compress_and_encrypt_file)

          result = backup.backup_database('qdrant://localhost:6333/collection', '/tmp/backup.snapshot')

          expect(result).to be false
          expect(backup).not_to have_received(:compress_and_encrypt_file)
        end

        it 'reports failure when encryption fails' do
          allow(backup).to receive_messages(backup_qdrant: true, compress_and_encrypt_file: false)

          result = backup.backup_database('qdrant://localhost:6333/collection', '/tmp/backup.snapshot')

          expect(result).to be false
        end
      end

      context 'with unsupported URL' do
        it 'returns false and posts to slack' do
          allow(backup).to receive(:post_to_slack)

          result = backup.backup_database('mongodb://localhost/db', '/tmp/backup.bson')

          expect(result).to be false
          expect(backup).to have_received(:post_to_slack).with(/Unsupported database URL format/)
        end
      end
    end
  end
end
