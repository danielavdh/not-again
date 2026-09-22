# frozen_string_literal: true

require "test_helper"

module Filing
  class StorageTest < ActiveSupport::TestCase
    setup do
      @entity = entities(:family_biz)
    end

    # ==================== filename_for ====================

    def filename(scheme: "gb_self_employment", period_end: Date.new(2026, 10, 5))
      Storage.filename_for(entity: @entity, scheme: scheme, period_end: period_end, group: "MTD")
    end

    test "filename_for uses entity code as top-level folder" do
      assert filename.start_with?("#{@entity.code}/")
    end

    test "filename_for uses group as second-level folder" do
      assert filename.start_with?("#{@entity.code}/MTD/")
    end

    test "filename_for encodes the period end date as YY-MM-DD" do
      assert_includes filename(period_end: Date.new(2026, 10, 5)), "26-10-05-"
    end

    test "filename_for keys on the period END, so each quarter is a distinct file" do
      q1 = filename(period_end: Date.new(2026, 6, 30))
      q2 = filename(period_end: Date.new(2026, 9, 30))
      q3 = filename(period_end: Date.new(2026, 12, 31))
      q4 = filename(period_end: Date.new(2027, 3, 31))
      assert_equal 4, [q1, q2, q3, q4].uniq.size,
                   "cumulative quarters must not collide on one filename"
    end

    test "filename_for uses SA103 form code for gb_self_employment" do
      assert_includes filename(scheme: "gb_self_employment"), "-SA103-"
    end

    test "filename_for uses SA105 form code for gb_property" do
      assert_includes filename(scheme: "gb_property"), "-SA105-"
    end

    test "filename_for ends with .html" do
      assert filename.end_with?(".html")
    end

    # ==================== upload / fetch_html round-trip ====================

    test "upload and fetch_html round-trip in test environment" do
      name    = filename(period_end: Date.new(2026, 6, 30))
      content = "<html><body><p>Test submission</p></body></html>"

      Storage.upload(name, content)
      result = Storage.fetch_html(name)

      assert_equal content, result
    ensure
      # Clean up the test file from local filesystem
      path = submissions_path(name)
      FileUtils.rm_f(path)
    end
  end
end
