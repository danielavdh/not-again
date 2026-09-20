# frozen_string_literal: true

require "test_helper"

module Filing
  class ArchiveAndNotifyJobTest < ActiveJob::TestCase
    include ActionMailer::TestHelper

    setup do
      @entity = entities(:family_biz)
      @admin  = admins(:sudo)
    end

    test "uploads the html then delivers the confirmation email" do
      filename = "#{@entity.code}/MTD/26-Q1-SA103-GB.html"
      html     = "<html><body>Stored submission</body></html>"

      assert_emails 1 do
        ArchiveAndNotifyJob.perform_now(
          entity_id:  @entity.id,
          admin_id:   @admin.id,
          scheme:     "gb_self_employment",
          start_date: Date.new(2026, 1, 1),
          end_date:   Date.new(2026, 3, 31),
          view_url:   "https://accounts.example.com/entities/#{@entity.id}/filing/view",
          filename:   filename,
          html:       html,
          locale:     "en"
        )
      end

      assert_equal html, Filing::Storage.fetch_html(filename)
    ensure
      FileUtils.rm_f(Rails.root.join("public", "tax_submissions", filename))
    end
  end
end
