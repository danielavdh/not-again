# frozen_string_literal: true
require "test_helper"
require "open3"

# A production instance can take every secret from the environment instead of an
# encrypted credentials file, so a deploy with no master key still boots and
# still reads the right values.
#
# This cannot be checked in-process — the initializers already ran once, at
# boot, against this suite's own environment. So it boots a real `bin/rails
# runner` in production with the environment a keyless deploy would have and
# reads back what the app resolved. The sentinel values differ from everything
# the real credentials hold, so a pass proves the environment won, which is
# strictly stronger than "works when credentials are absent": if ENV beats a
# readable credentials file, an unreadable one changes nothing.
class KeylessProductionConfigTest < ActiveSupport::TestCase
  ENV_FOR_KEYLESS_BOOT = {
    "RAILS_ENV"       => "production",
    "RAILS_MASTER_KEY" => "",
    "SECRET_KEY_BASE" => "0" * 128,
    "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"         => "primary-key-sentinel-0000000000000000000",
    "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"   => "deterministic-key-sentinel-000000000000000",
    "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "derivation-salt-sentinel-00000000000000000",
    "APP_HOST"        => "books.example.eu",
    "DATABASE_URL"    => "postgres://pguser:pgpw@db.sentinel.example:5432/sentinel_db",
    "S3_BUCKET"       => "sentinel-receipts-bucket",
    "S3_REGION"       => "sentinel-region",
    "S3_ENDPOINT"     => "https://s3.sentinel.example",
    "S3_ACCESS_KEY"   => "sentinel-access",
    "S3_SECRET_KEY"   => "sentinel-secret",
    "SMTP_ADDRESS"    => "smtp.sentinel.example",
    "SMTP_PORT"       => "2525",
    "SMTP_USERNAME"   => "sentinel-user",
    "SMTP_PASSWORD"   => "sentinel-pass",
    "SERVICE_NAME"    => "Sentinel Books",
    "CONTACT_NAME"    => "A Person",
    "CONTACT_EMAIL"   => "hi@sentinel.example",
    "CONTACT_TRADING" => "Sentinel",
    "CONTACT_STREET"  => "1 Sentinel Street",
    "CONTACT_CITY"    => "00000 Sentinel City",
    "CONTACT_COUNTRY" => "Sentinelland"
  }.freeze

  PROBE = <<~RUBY
    require "json"
    cfg = ActiveRecord::Base.configurations.configs_for(env_name: "production").first
    print "PROBE=" + {
      s3_bucket:    ObjectStorage::BUCKET,
      s3_endpoint:  ObjectStorage::ENDPOINT,
      smtp_address: ActionMailer::Base.smtp_settings[:address],
      smtp_port:    ActionMailer::Base.smtp_settings[:port],
      ar_primary:   Rails.application.config.active_record.encryption.primary_key,
      db_host:      cfg.host,
      db_name:      cfg.database,
      mail_from:    MAIL_FROM
    }.to_json
  RUBY

  def boot_and_probe(extra_env = {})
    env = ENV_FOR_KEYLESS_BOOT.merge(extra_env)
    out, err, status = Open3.capture3(env, Rails.root.join("bin/rails").to_s, "runner", PROBE,
                                      chdir: Rails.root.to_s)
    assert status.success?, "keyless production boot failed:\n#{err}"
    line = out[/^PROBE=(\{.*\})/, 1] or flunk "probe produced no JSON:\nSTDOUT:\n#{out}\nSTDERR:\n#{err}"
    JSON.parse(line, symbolize_names: true)
  end

  test "S3, SMTP and encryption keys are taken from the environment, overriding credentials" do
    r = boot_and_probe

    assert_equal "sentinel-receipts-bucket",    r[:s3_bucket],    "S3 bucket must come from S3_BUCKET"
    assert_equal "https://s3.sentinel.example", r[:s3_endpoint],  "S3 endpoint must come from S3_ENDPOINT"
    assert_equal "smtp.sentinel.example",       r[:smtp_address], "SMTP address must come from SMTP_ADDRESS"
    assert_equal 2525,                          r[:smtp_port],    "SMTP port must come from SMTP_PORT, as Integer"
    assert_equal "primary-key-sentinel-0000000000000000000", r[:ar_primary],
      "AR encryption primary key must come from ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"
  end

  test "DATABASE_URL wins over the DB_* keys when both are present" do
    r = boot_and_probe("DB_HOST" => "should-be-ignored", "DB_NAME" => "should_be_ignored")

    assert_equal "db.sentinel.example", r[:db_host], "DATABASE_URL host must win over DB_HOST"
    assert_equal "sentinel_db",         r[:db_name], "DATABASE_URL database must win over DB_NAME"
  end

  test "MAIL_FROM is read from the environment" do
    assert_equal "sender@sentinel.example",
      boot_and_probe("MAIL_FROM" => "sender@sentinel.example")[:mail_from]
  end
end
