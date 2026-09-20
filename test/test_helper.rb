ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require_relative "test_helpers/session_test_helper"

# Shrine's :cache storage is disposable by design — the permanent copy lands
# under public/uploads/<attachment>/ once promoted, never under cache/ — but
# nothing else clears it. Every real upload test writes straight to the
# filesystem, outside any transaction, so it survives AR rollback and piles up
# run after run.
#
# tax_exports for a sharper reason than tidiness: TaxExportStorage writes to
# tax_exports/<report id>/, ids climb with every run, and a new report
# eventually lands on an id some earlier run already wrote a file under. Then
# "a custom report's export is never backed up" finds that stale file and
# fails — intermittently, and only on a machine that has run the suite before.
# CI never sees it; a developer sees it and cannot reproduce it.
#
# Once, after the whole suite: per-worker would race four workers wiping mid-
# run.
Minitest.after_run do
  next unless Rails.env.test?
  FileUtils.rm_rf(Rails.root.join("public", "uploads", "cache"))
  FileUtils.rm_rf(Rails.root.join("public", "uploads", "tax_exports"))
end


module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    #parallelize(workers: :number_of_processors)
    parallelize(workers: 4)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical
    # order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # Joining a group always records today as the membership's start, which is
    # correct for the app — but most tests that group two entities are testing
    # something else and then post historical entries, which the real join date
    # would wrongly exclude from a family archive.
    #
    # Call AFTER the entity already has an entity_group, to backdate its join
    # far enough to cover whatever historical dates the test cares about.
    def backdate_family_membership!(entity, on: Date.new(2000, 1, 1))
      entity.entity_group_memberships.open.update_all(starts_on: on)
    end
  end
end

class ActionDispatch::IntegrationTest
  include SessionTestHelper
  
  def default_url_options
    { locale: I18n.default_locale }
  end
  
  setup do
    ActionMailer::Base.default_url_options = { host: "www.example.com" }

    # Currency memoises the supported-currency list in CLASS state, because
    # CurrencyConfig.symbol_for runs on every formatted amount and must not
    # query per call. Class state does not roll back.
    #
    # So a test that adds a currency leaves it in the cache after its
    # transaction is rolled away, and the NEXT test sees a currency that is not
    # in the database — order-dependent, which is the worst kind.
    Currency.expire_cache
  end
end
