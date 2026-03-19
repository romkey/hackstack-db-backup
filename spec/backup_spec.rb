require 'spec_helper'

RSpec.describe BackupService do
  let(:config) { create_test_config }
  let(:backup) { BackupService::Backup.new(config) }

  describe BackupService::Config do
    describe '#validate!' do
      it 'returns error when PARENT_DIR is nil' do
        config = BackupService::Config.new
        config.parent_dir = nil
        config.dest_dir = '/test/dest'

        errors = config.validate!
        expect(errors).to include("PARENT_DIR environment variable is not set")
      end

      it 'returns error when PARENT_DIR is empty' do
        config = BackupService::Config.new
        config.parent_dir = ''
        config.dest_dir = '/test/dest'

        errors = config.validate!
        expect(errors).to include("PARENT_DIR environment variable is not set")
      end

      it 'returns error when DEST_DIR is nil' do
        config = BackupService::Config.new
        config.parent_dir = '/tmp'
        config.dest_dir = nil

        errors = config.validate!
        expect(errors).to include("DEST_DIR environment variable is not set")
      end

      it 'returns error when DEST_DIR is empty' do
        config = BackupService::Config.new
        config.parent_dir = '/tmp'
        config.dest_dir = ''

        errors = config.validate!
        expect(errors).to include("DEST_DIR environment variable is not set")
      end

      it 'returns error when PARENT_DIR does not exist' do
        config = BackupService::Config.new
        config.parent_dir = '/nonexistent/path'
        config.dest_dir = '/test/dest'

        errors = config.validate!
        expect(errors).to include("PARENT_DIR does not exist: /nonexistent/path")
      end

      it 'returns empty array when configuration is valid' do
        config = BackupService::Config.new
        config.parent_dir = '/tmp'
        config.dest_dir = '/tmp'

        errors = config.validate!
        expect(errors).to be_empty
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
          url = "postgresql://user:p'ss\$word@localhost:5432/mydb"
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
          url = "mysql://user:p'ss\$word@localhost:3306/mydb"
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
        File.write('/test/app/.env', "BACKUP_DATABASE_URLS=\"postgresql://u:p@h:5432/db1\",\"mysql://u:p@h:3306/db2\"\n")

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

    describe '#categorize_backups' do
      let(:config) do
        create_test_config(
          retain_hourly: 3,
          retain_daily: 2,
          retain_weekly: 2,
          retain_monthly: 2,
          retain_yearly: 2
        )
      end
      let(:backup) { BackupService::Backup.new(config) }

      it 'categorizes backups into hourly buckets' do
        files = [
          '/backup/backup-db-20240115100000.sql.bz2',
          '/backup/backup-db-20240115103000.sql.bz2',
          '/backup/backup-db-20240115110000.sql.bz2',
          '/backup/backup-db-20240115113000.sql.bz2',
          '/backup/backup-db-20240115120000.sql.bz2'
        ]

        result = backup.categorize_backups(files)

        expect(result[:hourly].size).to eq(3)
        expect(result[:hourly]).to include('/backup/backup-db-20240115120000.sql.bz2')
        expect(result[:hourly]).to include('/backup/backup-db-20240115113000.sql.bz2')
        expect(result[:hourly]).to include('/backup/backup-db-20240115103000.sql.bz2')
      end

      it 'keeps newest backup per hour' do
        files = [
          '/backup/backup-db-20240115100000.sql.bz2',
          '/backup/backup-db-20240115103000.sql.bz2'
        ]

        result = backup.categorize_backups(files)

        expect(result[:hourly]).to include('/backup/backup-db-20240115103000.sql.bz2')
        expect(result[:hourly]).not_to include('/backup/backup-db-20240115100000.sql.bz2')
      end

      it 'categorizes backups into daily buckets' do
        files = [
          '/backup/backup-db-20240113120000.sql.bz2',
          '/backup/backup-db-20240114120000.sql.bz2',
          '/backup/backup-db-20240115120000.sql.bz2'
        ]

        result = backup.categorize_backups(files)

        expect(result[:daily].size).to eq(2)
        expect(result[:daily]).to include('/backup/backup-db-20240115120000.sql.bz2')
        expect(result[:daily]).to include('/backup/backup-db-20240114120000.sql.bz2')
      end

      it 'categorizes backups into weekly buckets' do
        files = [
          '/backup/backup-db-20240101120000.sql.bz2',
          '/backup/backup-db-20240108120000.sql.bz2',
          '/backup/backup-db-20240115120000.sql.bz2'
        ]

        result = backup.categorize_backups(files)

        expect(result[:weekly].size).to eq(2)
      end

      it 'categorizes backups into monthly buckets' do
        files = [
          '/backup/backup-db-20231115120000.sql.bz2',
          '/backup/backup-db-20231215120000.sql.bz2',
          '/backup/backup-db-20240115120000.sql.bz2'
        ]

        result = backup.categorize_backups(files)

        expect(result[:monthly].size).to eq(2)
      end

      it 'categorizes backups into yearly buckets' do
        files = [
          '/backup/backup-db-20220115120000.sql.bz2',
          '/backup/backup-db-20230115120000.sql.bz2',
          '/backup/backup-db-20240115120000.sql.bz2'
        ]

        result = backup.categorize_backups(files)

        expect(result[:yearly].size).to eq(2)
      end

      it 'handles empty file list' do
        result = backup.categorize_backups([])

        expect(result[:hourly]).to eq([])
        expect(result[:daily]).to eq([])
        expect(result[:weekly]).to eq([])
        expect(result[:monthly]).to eq([])
        expect(result[:yearly]).to eq([])
      end

      it 'ignores files with unparseable timestamps' do
        files = [
          '/backup/backup-db-20240115120000.sql.bz2',
          '/backup/invalid-file.sql.bz2'
        ]

        result = backup.categorize_backups(files)

        expect(result[:hourly]).to eq(['/backup/backup-db-20240115120000.sql.bz2'])
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
      let(:backup) { BackupService::Backup.new(config) }

      before do
        FileUtils.mkdir_p('/test/dest/myapp')
      end

      it 'deletes files beyond retention limits' do
        files = [
          '/test/dest/myapp/backup-db-20240115100000.sql.bz2',
          '/test/dest/myapp/backup-db-20240115110000.sql.bz2',
          '/test/dest/myapp/backup-db-20240115120000.sql.bz2',
          '/test/dest/myapp/backup-db-20240115130000.sql.bz2'
        ]
        files.each { |f| FileUtils.touch(f) }

        backup.cleanup_old_backups('/test/parent/myapp')

        expect(File.exist?('/test/dest/myapp/backup-db-20240115130000.sql.bz2')).to be true
        expect(File.exist?('/test/dest/myapp/backup-db-20240115120000.sql.bz2')).to be true
      end

      it 'groups files by database name' do
        FileUtils.touch('/test/dest/myapp/backup-db1-20240115120000.sql.bz2')
        FileUtils.touch('/test/dest/myapp/backup-db2-20240115120000.sql.bz2')

        backup.cleanup_old_backups('/test/parent/myapp')

        expect(File.exist?('/test/dest/myapp/backup-db1-20240115120000.sql.bz2')).to be true
        expect(File.exist?('/test/dest/myapp/backup-db2-20240115120000.sql.bz2')).to be true
      end

      it 'handles mixed file types' do
        FileUtils.touch('/test/dest/myapp/backup-db-20240115120000.sql.bz2')
        FileUtils.touch('/test/dest/myapp/backup-vectors-20240115120000.snapshot.bz2')

        backup.cleanup_old_backups('/test/parent/myapp')

        expect(File.exist?('/test/dest/myapp/backup-db-20240115120000.sql.bz2')).to be true
        expect(File.exist?('/test/dest/myapp/backup-vectors-20240115120000.snapshot.bz2')).to be true
      end

      it 'does nothing when backup directory does not exist' do
        expect { backup.cleanup_old_backups('/test/parent/nonexistent') }.not_to raise_error
      end
    end

    describe '#post_to_slack' do
      let(:config) { create_test_config(slack_webhook_url: 'https://hooks.slack.com/services/T00/B00/XXX', quiet: true) }
      let(:backup) { BackupService::Backup.new(config) }

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
        backup = BackupService::Backup.new(config)

        expect { backup.post_to_slack('Test message') }.not_to raise_error
        expect(WebMock).not_to have_requested(:post, /slack/)
      end

      it 'does nothing when webhook URL is empty' do
        config = create_test_config(slack_webhook_url: '')
        backup = BackupService::Backup.new(config)

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
      let(:backup) { BackupService::Backup.new(config) }

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
      let(:backup) { BackupService::Backup.new(config) }

      context 'with Qdrant URL' do
        it 'calls backup_qdrant and compress_file on success' do
          allow(backup).to receive(:backup_qdrant).and_return(true)
          allow(backup).to receive(:compress_file).and_return(true)

          result = backup.backup_database('qdrant://localhost:6333/collection', '/tmp/backup.snapshot')

          expect(result).to be true
          expect(backup).to have_received(:backup_qdrant).with('localhost', '6333', 'collection', nil, '/tmp/backup.snapshot')
          expect(backup).to have_received(:compress_file).with('/tmp/backup.snapshot')
        end

        it 'extracts API key from URL' do
          allow(backup).to receive(:backup_qdrant).and_return(true)
          allow(backup).to receive(:compress_file).and_return(true)

          backup.backup_database('qdrant://my-key@localhost:6333/collection', '/tmp/backup.snapshot')

          expect(backup).to have_received(:backup_qdrant).with('localhost', '6333', 'collection', 'my-key', '/tmp/backup.snapshot')
        end

        it 'does not compress on failure' do
          allow(backup).to receive(:backup_qdrant).and_return(false)
          allow(backup).to receive(:compress_file)

          result = backup.backup_database('qdrant://localhost:6333/collection', '/tmp/backup.snapshot')

          expect(result).to be false
          expect(backup).not_to have_received(:compress_file)
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
