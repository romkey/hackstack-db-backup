require 'spec_helper'
require_relative '../app/backup-crypt'

RSpec.describe BackupService::Crypt do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:crypt) { described_class.new(out: out, err: err) }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      original_env = ENV.to_hash
      begin
        ENV.delete('DEST_DIR')
        ENV.delete('BACKUP_ENCRYPTION_RECIPIENTS')
        example.run
      ensure
        ENV.replace(original_env)
      end
    end
  end

  # Stands in for the age binary: records the invocation and writes a
  # plausible age file so the header check passes.
  def stub_age(success: true, header: BackupService::AGE_HEADER)
    allow(Open3).to receive(:capture3) do |*args|
      if success
        output_index = args.index('-o')
        File.write(args[output_index + 1], "#{header}\n-> X25519 payload\n") if output_index
      end
      status = instance_double(Process::Status, success?: success)
      ['', success ? '' : 'age: bad recipient', status]
    end
  end

  def backup_file(name, contents = 'compressed data')
    path = File.join(@tmpdir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  describe '#run' do
    it 'prints usage with no arguments' do
      expect(crypt.run([])).to eq(0)
      expect(out.string).to include('Usage: backup-crypt.rb')
    end

    it 'prints usage for --help' do
      expect(crypt.run(['--help'])).to eq(0)
      expect(out.string).to include('keygen')
      expect(out.string).to include('encrypt')
      expect(out.string).to include('decrypt')
    end

    it 'rejects an unknown command' do
      expect(crypt.run(['frobnicate'])).to eq(1)
      expect(err.string).to include('Unknown command: frobnicate')
    end

    it 'reports invalid options without raising' do
      expect(crypt.run(['encrypt', '--nonsense'])).to eq(1)
      expect(err.string).to include('invalid option')
    end
  end

  describe 'keygen' do
    it 'refuses to overwrite an existing identity' do
      path = backup_file('existing.key', 'AGE-SECRET-KEY-1')

      expect(crypt.run(['keygen', '-o', path])).to eq(1)
      expect(err.string).to include('Refusing to overwrite')
      expect(File.read(path)).to eq('AGE-SECRET-KEY-1')
    end
  end

  describe 'encrypt' do
    it 'requires at least one recipient' do
      expect(crypt.run(['encrypt', @tmpdir])).to eq(1)
      expect(err.string).to include('No recipients given')
    end

    it 'rejects a malformed recipient' do
      expect(crypt.run(['encrypt', '-r', 'nope', @tmpdir])).to eq(1)
      expect(err.string).to include('Invalid age recipient')
    end

    it 'rejects a missing recipients file' do
      expect(crypt.run(['encrypt', '-R', File.join(@tmpdir, 'absent.txt'), @tmpdir])).to eq(1)
      expect(err.string).to include('Recipients file does not exist')
    end

    it 'reads recipients from a file' do
      recipients_file = backup_file('recipients.txt', "# team\n#{TEST_AGE_RECIPIENT}\n")
      backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2')
      stub_age

      expect(crypt.run(['encrypt', '-R', recipients_file, @tmpdir])).to eq(0)
      expect(Open3).to have_received(:capture3).with(
        'age', '-r', TEST_AGE_RECIPIENT, '-o', anything, anything
      )
    end

    it 'falls back to BACKUP_ENCRYPTION_RECIPIENTS' do
      ENV['BACKUP_ENCRYPTION_RECIPIENTS'] = TEST_AGE_RECIPIENT
      backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2')
      stub_age

      expect(crypt.run(['encrypt', @tmpdir])).to eq(0)
      expect(out.string).to include('Encrypted 1, skipped 0, failed 0')
    end

    it 'passes every recipient to age' do
      backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2')
      stub_age

      crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, '-r', TEST_AGE_RECIPIENT_2, @tmpdir])

      expect(Open3).to have_received(:capture3).with(
        'age', '-r', TEST_AGE_RECIPIENT, '-r', TEST_AGE_RECIPIENT_2, '-o', anything, anything
      )
    end

    it 'falls back to DEST_DIR when no paths are given' do
      ENV['DEST_DIR'] = @tmpdir
      backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2')
      stub_age

      expect(crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT])).to eq(0)
      expect(out.string).to include('Encrypted 1')
    end

    it 'fails when no paths are given and DEST_DIR is unset' do
      expect(crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT])).to eq(1)
      expect(err.string).to include('DEST_DIR is not set')
    end

    it 'reports missing paths' do
      expect(crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, '/no/such/path'])).to eq(1)
      expect(err.string).to include('Not found: /no/such/path')
    end

    context 'with a mixed archive' do
      before do
        backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2')
        backup_file('myapp/daily/backup-db-20240115130000.sql.bz2.age')
        backup_file('myapp/notes.txt')
      end

      it 'encrypts only unencrypted backups' do
        stub_age

        expect(crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])).to eq(0)
        expect(Open3).to have_received(:capture3).once
        expect(out.string).to include('Encrypted 1, skipped 0, failed 0')
      end

      it 'replaces the plaintext backup with an encrypted one' do
        stub_age
        source = File.join(@tmpdir, 'myapp/hourly/backup-db-20240115120000.sql.bz2')

        crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])

        expect(File.exist?(source)).to be false
        expect(File.exist?("#{source}.age")).to be true
      end

      it 'leaves unrelated files alone' do
        stub_age

        crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])

        expect(File.exist?(File.join(@tmpdir, 'myapp/notes.txt'))).to be true
      end

      it 'is idempotent across runs' do
        stub_age
        crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])

        second = described_class.new(out: (second_out = StringIO.new), err: err)
        expect(second.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])).to eq(0)
        expect(second_out.string).to include('No unencrypted backups found')
      end
    end

    context 'with --dry-run' do
      it 'changes nothing' do
        source = backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2')
        allow(Open3).to receive(:capture3)

        expect(crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, '--dry-run', @tmpdir])).to eq(0)

        expect(File.exist?(source)).to be true
        expect(File.exist?("#{source}.age")).to be false
        expect(Open3).not_to have_received(:capture3)
        expect(out.string).to include('Would encrypt')
        expect(out.string).to include('Dry run: no files were changed')
      end
    end

    context 'when age fails' do
      let!(:source) { backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2') }

      it 'keeps the plaintext backup and reports failure' do
        stub_age(success: false)

        expect(crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])).to eq(1)
        expect(File.exist?(source)).to be true
        expect(err.string).to include('Failed to encrypt')
      end

      it 'removes the partial output' do
        stub_age(success: false)

        crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])

        expect(Dir.glob(File.join(@tmpdir, '**', '*.part'))).to be_empty
      end

      it 'rejects output that is not an age file' do
        stub_age(header: 'not-an-age-file')

        expect(crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])).to eq(1)
        expect(File.exist?(source)).to be true
        expect(File.exist?("#{source}.age")).to be false
        expect(err.string).to include('not a valid age file')
      end
    end

    it 'skips a backup whose encrypted counterpart already exists' do
      source = backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2')
      backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2.age')
      allow(Open3).to receive(:capture3)

      expect(crypt.run(['encrypt', '-r', TEST_AGE_RECIPIENT, @tmpdir])).to eq(0)
      expect(File.exist?(source)).to be true
      expect(Open3).not_to have_received(:capture3)
      expect(out.string).to include('already exists')
    end
  end

  describe 'decrypt' do
    let(:identity) { backup_file('id.key', 'AGE-SECRET-KEY-1TEST') }

    it 'requires an identity' do
      expect(crypt.run(['decrypt', @tmpdir])).to eq(1)
      expect(err.string).to include('identity file is required')
    end

    it 'rejects a missing identity file' do
      expect(crypt.run(['decrypt', '-i', File.join(@tmpdir, 'absent.key'), @tmpdir])).to eq(1)
      expect(err.string).to include('Identity file does not exist')
    end

    it 'decrypts encrypted backups' do
      encrypted = backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2.age')
      allow(Open3).to receive(:capture3) do |*args|
        File.write(args[args.index('-o') + 1], 'decrypted')
        ['', '', instance_double(Process::Status, success?: true)]
      end

      expect(crypt.run(['decrypt', '-i', identity, @tmpdir])).to eq(0)
      expect(File.exist?(encrypted.sub(/\.age\z/, ''))).to be true
      expect(out.string).to include('Decrypted 1, skipped 0, failed 0')
    end

    it 'ignores unencrypted backups' do
      backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2')
      allow(Open3).to receive(:capture3)

      expect(crypt.run(['decrypt', '-i', identity, @tmpdir])).to eq(0)
      expect(out.string).to include('No encrypted backups found')
      expect(Open3).not_to have_received(:capture3)
    end

    it 'does not overwrite an existing decrypted file without --force' do
      backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2.age')
      existing = backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2', 'original')
      allow(Open3).to receive(:capture3)

      expect(crypt.run(['decrypt', '-i', identity, @tmpdir])).to eq(0)
      expect(File.read(existing)).to eq('original')
      expect(out.string).to include('already exists')
    end

    it 'reports failure and removes partial output when age fails' do
      backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2.age')
      allow(Open3).to receive(:capture3).and_return(
        ['', 'no identity matched', instance_double(Process::Status, success?: false)]
      )

      expect(crypt.run(['decrypt', '-i', identity, @tmpdir])).to eq(1)
      expect(err.string).to include('Failed to decrypt')
      expect(Dir.glob(File.join(@tmpdir, '**', '*.part'))).to be_empty
    end

    it 'keeps status messages off stdout in --stdout mode' do
      encrypted = backup_file('myapp/hourly/backup-db-20240115120000.sql.bz2.age')
      allow(crypt).to receive(:system).and_return(true)

      expect(crypt.run(['decrypt', '-i', identity, '--stdout', encrypted])).to eq(0)
      expect(out.string).to be_empty
      expect(err.string).to include('Decrypted 1')
    end
  end
end
