# frozen_string_literal: true
require "test_helper"

class TaxExportStorageTest < ActiveSupport::TestCase
  setup do
    @report_id = rand(100_000..999_999)
  end

  teardown do
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "tax_exports", @report_id.to_s))
  end

  test "upload then list then read round-trips, newest first" do
    older = TaxExportStorage.key_for(@report_id, Time.new(2026, 1, 1, 10, 0, 0))
    newer = TaxExportStorage.key_for(@report_id, Time.new(2026, 6, 1, 10, 0, 0))
    TaxExportStorage.upload(older, "old content")
    TaxExportStorage.upload(newer, "new content")

    entries = TaxExportStorage.list(@report_id)
    assert_equal [ newer, older ], entries.map(&:key)
    assert_equal "new content", TaxExportStorage.read(entries.first.key)
  end

  test "two exports in the same second get distinct keys, not a silent overwrite" do
    t = Time.new(2026, 3, 1, 9, 0, 0)
    first  = TaxExportStorage.key_for(@report_id, t)
    second = TaxExportStorage.key_for(@report_id, t)
    assert_not_equal first, second, "same-second exports must not collide on one key"

    TaxExportStorage.upload(first,  "first")
    TaxExportStorage.upload(second, "second")
    assert_equal 2, TaxExportStorage.list(@report_id).size, "the first must not have been overwritten"
  end

  # Shrine hands back bytes as ASCII-8BIT. Every scheme's own CSV header carries
  # a real em dash, so a naive read compares != against the freshly generated
  # UTF-8 string on the very first export, defeating TaxExportJob's dedupe
  # permanently. #read must force UTF-8 for this comparison to mean anything.
  test "read returns content that compares equal to non-ASCII UTF-8 text" do
    original = "Form,Summary — the total for each line"
    TaxExportStorage.upload(TaxExportStorage.key_for(@report_id, Time.current), original)
    assert_equal original, TaxExportStorage.latest_content(@report_id)
  end

  test "latest_content is nil for a report with no backups yet" do
    assert_nil TaxExportStorage.latest_content(@report_id)
  end

  test "latest_content returns the newest backup's own bytes" do
    TaxExportStorage.upload(TaxExportStorage.key_for(@report_id, Time.new(2026, 1, 1)), "old")
    TaxExportStorage.upload(TaxExportStorage.key_for(@report_id, Time.new(2026, 2, 1)), "new")
    assert_equal "new", TaxExportStorage.latest_content(@report_id)
  end

  test "delete_report removes every backup under that report and no other" do
    other_id = @report_id + 1
    TaxExportStorage.upload(TaxExportStorage.key_for(@report_id, Time.current), "mine")
    TaxExportStorage.upload(TaxExportStorage.key_for(other_id, Time.current), "not mine")

    TaxExportStorage.delete_report(@report_id)

    assert_empty TaxExportStorage.list(@report_id)
    assert_equal 1, TaxExportStorage.list(other_id).size
  ensure
    FileUtils.rm_rf(Rails.root.join("public", "uploads", "tax_exports", other_id.to_s))
  end
end
