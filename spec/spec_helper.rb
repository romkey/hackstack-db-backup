require 'webmock/rspec'
require 'timecop'
require 'fakefs/spec_helpers'
require 'fileutils'

require_relative '../app/backup'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = "doc" if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed

  config.before(:each) do
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  config.after(:each) do
    Timecop.return
  end
end

def create_test_config(overrides = {})
  config = BackupService::Config.new
  config.parent_dir = overrides[:parent_dir] || '/test/parent'
  config.dest_dir = overrides[:dest_dir] || '/test/dest'
  config.slack_webhook_url = overrides[:slack_webhook_url]
  config.quiet = overrides.fetch(:quiet, true)
  config.backup_interval_minutes = overrides[:backup_interval_minutes] || 60
  config.retain_hourly = overrides[:retain_hourly] || 6
  config.retain_daily = overrides[:retain_daily] || 6
  config.retain_weekly = overrides[:retain_weekly] || 6
  config.retain_monthly = overrides[:retain_monthly] || 6
  config.retain_yearly = overrides[:retain_yearly] || 6
  config
end
