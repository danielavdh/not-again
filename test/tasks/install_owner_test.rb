# frozen_string_literal: true

require "test_helper"
require "rake"

# A hosted install has no terminal. `install:owner_if_missing` runs from the
# platform's post-deploy hook, and it is the ONLY way into a fresh installation
# there: every page needs a login, and only an owner can create one.
#
# Two ways it could betray that: by failing the deploy on the second run, and by
# staying a way in after the installation has an owner.
class InstallOwnerTest < ActiveSupport::TestCase
  setup do
    Rake.application.rake_require("tasks/install") unless Rake::Task.task_defined?("install:owner_if_missing")
    Rake::Task.define_task(:environment)
    %w[install:owner install:owner_if_missing].each { |t| Rake::Task[t].reenable }
    @env = ENV.to_h.slice("OWNER_USERNAME", "OWNER_EMAIL", "OWNER_PASSWORD")
  end

  teardown do
    %w[OWNER_USERNAME OWNER_EMAIL OWNER_PASSWORD].each { |k| ENV.delete(k) }
    @env.each { |k, v| ENV[k] = v }
  end

  # A fresh installation has no admins at all. The fixtures' other rows point at
  # them, and they are rolled back with the test, so the constraints are lifted
  # for the delete rather than every table being emptied in dependency order.
  def empty_installation!
    ActiveRecord::Base.connection.disable_referential_integrity { Admin.delete_all }
  end

  def run_task(username: "hosted_owner", password: "a-long-enough-password", email: "owner@example.com")
    ENV["OWNER_USERNAME"] = username
    ENV["OWNER_EMAIL"] = email
    ENV["OWNER_PASSWORD"] = password
    capture_io { Rake::Task["install:owner_if_missing"].invoke }
  end

  test "on an empty installation it creates an owner who can actually sign in" do
    empty_installation!

    run_task

    admin = Admin.sole
    assert admin.sudo?, "the first admin must be the owner, or nobody can administer the installation"
    assert admin.authenticate("a-long-enough-password"), "the password from the environment must be the one that works"
    assert_equal "owner@example.com", admin.email_address
  end

  # It runs on EVERY deploy. Aborting once an owner exists would fail the second
  # deploy of every hosted installation.
  test "it succeeds and changes nothing when an admin already exists" do
    before = Admin.order(:id).pluck(:id, :username, :sudo)
    assert_not_empty before, "fixtures should have admins — otherwise this proves nothing"

    assert_nothing_raised { run_task(username: "second_owner") }

    assert_equal before, Admin.order(:id).pluck(:id, :username, :sudo)
    assert_nil Admin.find_by(username: "second_owner"), "it must not add an owner to a running installation"
  end

  test "it refuses to invent an owner when the platform passed no credentials" do
    empty_installation!

    assert_raises(SystemExit) { capture_io { Rake::Task["install:owner_if_missing"].invoke } }
    assert_equal 0, Admin.count
  end
end
