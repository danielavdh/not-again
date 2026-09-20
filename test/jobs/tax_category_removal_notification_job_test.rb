# frozen_string_literal: true
require "test_helper"

# The notification that makes a catalogue deletion audible.
#
# An account tagged with a removed key keeps a non-blank tax_category_key, so it
# never appears in the "needs tagging" list — and the export and the HMRC
# payload both skip a category they cannot resolve. Its figures leave the return
# in silence, and this job is the only thing that says so.
class TaxCategoryRemovalNotificationJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    ActionMailer::Base.deliveries.clear
    @entity  = entities(:personal)          # code "01", admins(:one) has full access
    @account = accounts(:boss_bank)         # 101001 → entity 01
    @account.update!(tax_scheme: "de_euer", tax_category_key: "gone_key")
    @admin = admins(:one)
  end

  def run_job(keys: ["gone_key"], scheme: "de_euer")
    TaxCategoryRemovalNotificationJob.perform_now(
      scheme: scheme, tax_year: 2026, removed_keys: keys
    )
  end

  test "emails the full-access bookkeeper of an affected account" do
    assert_emails 1 do
      run_job
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal [@admin.email_address], mail.to
    assert_match @account.code, mail.body.encoded
    assert_match "gone_key", mail.body.encoded
  end

  test "says nothing when no account used the removed key" do
    @account.update!(tax_category_key: "something_else")
    assert_no_emails { run_job }
  end

  test "says nothing when the key belongs to another scheme" do
    assert_no_emails { run_job(scheme: "de_vermietung") }
  end

  test "nothing to do with no keys" do
    assert_no_emails { run_job(keys: []) }
  end

  # A read_only or upload_receipts co-admin cannot re-tag an account, so telling
  # them would be noise they can do nothing about.
  test "co-admins who cannot re-tag are not told" do
    reader = admins(:read_only)   # read_only on personal(01)
    assert_emails 1 do
      run_job
    end
    recipients = ActionMailer::Base.deliveries.last(1).flat_map(&:to)
    assert_not_includes recipients, reader.email_address
  end

  test "each bookkeeper is told about their own accounts only" do
    # admins(:two) holds family_biz(10); give it a stranded account too.
    other = accounts(:bank_gbp)             # 110001 → entity 10
    other.update!(tax_scheme: "de_euer", tax_category_key: "gone_key")

    run_job

    mails = ActionMailer::Base.deliveries
    to_one = mails.find { |m| m.to == [admins(:one).email_address] }
    to_two = mails.find { |m| m.to == [admins(:two).email_address] }

    assert to_one, "the bookkeeper of entity 01 should have been told"
    assert to_two, "the bookkeeper of entity 10 should have been told"

    assert_match     @account.code, to_one.body.encoded
    assert_no_match(/#{other.code}/, to_one.body.encoded,
      "one bookkeeper should not see another business's accounts")
    assert_match     other.code, to_two.body.encoded
  end
end
