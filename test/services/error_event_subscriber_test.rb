# frozen_string_literal: true

require "test_helper"

# What Rails hands the subscriber, and what may reach the table. The rule this
# guards is the privacy one: a crash report must say where the code broke and
# nothing about what anyone typed.
class ErrorEventSubscriberTest < ActiveSupport::TestCase
  FakeRequest = Struct.new(:path, :query_string, keyword_init: true)

  class FakeController
    attr_reader :request, :action_name

    def initialize(path:, action: "show")
      @request = FakeRequest.new(path: path, query_string: "q=Mueller&amount=1200")
      @action_name = action
    end
  end

  setup do
    @subscriber = ErrorEventSubscriber.new
    @error = ActiveRecord::RecordNotFound.new("Couldn't find Report with id=41")
    @error.set_backtrace([
      "#{Rails.root}/app/controllers/reports_controller.rb:88:in 'show'",
      "#{Gem.dir}/gems/actionpack-8.1.3.1/lib/action_controller/metal.rb:1:in 'call'"
    ])
  end

  def report(handled: false, context: {})
    @subscriber.report(@error, handled: handled, severity: :error, context: context)
  end

  test "an unhandled controller error is recorded with its action, path and code line" do
    report(context: { controller: FakeController.new(path: "/en/reports/41") })

    row = ErrorEvent.sole
    assert_equal "ActiveRecord::RecordNotFound", row.error_class
    assert_equal "ErrorEventSubscriberTest::FakeController#show", row.source
    assert_equal "/en/reports/41", row.last_path
    assert_equal "app/controllers/reports_controller.rb:88", row.last_line
  end

  # The query string is where the content lives — a search term is somebody's
  # name, a filter is their figures. The path says which page, which is what a
  # fix needs.
  test "nothing from the query string is stored" do
    report(context: { controller: FakeController.new(path: "/en/journal_entries") })

    row = ErrorEvent.sole
    assert_equal "/en/journal_entries", row.last_path
    ErrorEvent.column_names.each do |column|
      assert_not_includes row[column].to_s, "Mueller", "#{column} leaked the query string"
      assert_not_includes row[column].to_s, "1200", "#{column} leaked the query string"
    end
  end

  # A handled error is code rescuing what it expected — the app working. Storing
  # those would bury the 500s in noise.
  test "a handled error is not recorded" do
    report(handled: true, context: { controller: FakeController.new(path: "/en/reports/41") })

    assert_equal 0, ErrorEvent.count
  end

  test "a job error is recorded under the job's name" do
    report(context: { job: TaxExportJob.new })

    assert_equal "TaxExportJob", ErrorEvent.sole.source
    assert_nil ErrorEvent.sole.last_path
  end

  # Middleware and boot-time failures have neither. They still matter, and
  # "(unknown)" is an honest answer where a guess would not be.
  test "an error with no controller and no job is still recorded" do
    report(context: {})

    assert_equal "(unknown)", ErrorEvent.sole.source
  end

  # The line that matters is the one in this app; the frames above it are the
  # framework, identical for every error of this class.
  test "the code line is the first frame inside this app, not the framework's" do
    @error.set_backtrace([
      "#{Gem.dir}/gems/activerecord-8.1.3.1/lib/active_record/core.rb:250:in 'find'",
      "#{Rails.root}/app/services/reports/presenter.rb:83:in 'build'"
    ])
    report(context: {})

    assert_equal "app/services/reports/presenter.rb:83", ErrorEvent.sole.last_line
  end

  # The class being right is worth nothing if nothing calls it. This goes
  # through Rails.error, which is what the framework uses for every unhandled
  # exception, so it fails if the initializer stops subscribing.
  test "Rails.error reaches the table" do
    Rails.error.report(ArgumentError.new("boom"), handled: false)

    assert_equal "ArgumentError", ErrorEvent.sole.error_class
  end

  test "an error raised entirely inside the framework records no line, and still records" do
    @error.set_backtrace([ "#{Gem.dir}/gems/rack/lib/rack.rb:9:in 'call'" ])
    report(context: {})

    assert_nil ErrorEvent.sole.last_line
    assert_equal "ActiveRecord::RecordNotFound", ErrorEvent.sole.error_class
  end
end
