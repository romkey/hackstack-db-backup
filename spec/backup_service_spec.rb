require 'spec_helper'

RSpec.describe BackupService do
  describe '.parse_recipient_list' do
    it 'returns an empty array for nil' do
      expect(described_class.parse_recipient_list(nil)).to eq([])
    end

    it 'returns an empty array for blank strings' do
      expect(described_class.parse_recipient_list('   ')).to eq([])
    end

    it 'splits comma-separated recipients and trims whitespace' do
      value = "#{TEST_AGE_RECIPIENT}, #{TEST_AGE_RECIPIENT_2}"
      expect(described_class.parse_recipient_list(value)).to eq([TEST_AGE_RECIPIENT, TEST_AGE_RECIPIENT_2])
    end
  end

  describe '.read_recipients_file' do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    it 'ignores blank lines and comments' do
      path = File.join(@tmpdir, 'recipients.txt')
      File.write(path, "# ops team\n\n#{TEST_AGE_RECIPIENT}\n")

      expect(described_class.read_recipients_file(path)).to eq([TEST_AGE_RECIPIENT])
    end
  end

  describe '.valid_age_recipient?' do
    it 'accepts age and SSH public keys' do
      expect(described_class.valid_age_recipient?(TEST_AGE_RECIPIENT)).to be true
      expect(described_class.valid_age_recipient?('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user@host')).to be true
    end

    it 'rejects nil, blank strings, and identity files' do
      expect(described_class.valid_age_recipient?(nil)).to be false
      expect(described_class.valid_age_recipient?('')).to be false
      expect(described_class.valid_age_recipient?('AGE-SECRET-KEY-1QQPQY')).to be false
    end
  end

  describe '.age_file?' do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    it 'detects the age version header' do
      path = File.join(@tmpdir, 'backup.age')
      File.write(path, "#{BackupService::AGE_HEADER}\n-> X25519 payload\n")

      expect(described_class.age_file?(path)).to be true
    end

    it 'rejects empty and non-age files' do
      empty = File.join(@tmpdir, 'empty')
      plain = File.join(@tmpdir, 'plain')
      File.write(empty, '')
      File.write(plain, 'BZh91AY&SY')

      expect(described_class.age_file?(empty)).to be false
      expect(described_class.age_file?(plain)).to be false
      expect(described_class.age_file?(File.join(@tmpdir, 'missing'))).to be false
    end
  end
end
