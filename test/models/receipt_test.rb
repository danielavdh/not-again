# frozen_string_literal: true

require "test_helper"

class ReceiptTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:family_biz)
    @personal_entity = entities(:personal)
    @posting = postings(:deposit_bank)
    @linked = receipts(:linked_receipt)
    @unlinked = receipts(:unlinked_receipt)
    @personal = receipts(:personal_receipt)
    @uploaded = receipts(:uploaded_receipt)
  end

  # ==================== Validations ====================

  test "valid receipt with all required attributes" do
    assert @linked.valid?
  end

  test "requires title" do
    @linked.title = nil
    assert_not @linked.valid?
    assert @linked.errors[:title].present?
  end

  test "title cannot exceed 100 characters" do
    @linked.title = "a" * 101
    assert_not @linked.valid?
    assert @linked.errors[:title].present?
  end

  test "title at exactly 100 characters is valid" do
    @linked.title = "a" * 100
    assert @linked.valid?
  end

  test "requires receipt_date" do
    @linked.receipt_date = nil
    assert_not @linked.valid?
    assert @linked.errors[:receipt_date].present?
  end

  test "requires scan on create" do
    receipt = Receipt.new(
      title: "Test",
      receipt_date: Date.current,
      entity_id: @entity.id
    )
    assert_not receipt.valid?
    assert receipt.errors[:scan].present?
  end

  test "does not require scan on update" do
    @linked.title = "Updated Title"
    assert @linked.valid?
  end

  test "requires entity_id when not nested via posting" do
    receipt = Receipt.new(
      title: "Test",
      receipt_date: Date.current,
      entity_id: nil,
      posting_id: nil
    )
    receipt.valid?
    assert receipt.errors[:entity_id].present?
  end

  test "does not require entity_id when nested via posting" do
    receipt = Receipt.new(
      title: "Test",
      receipt_date: Date.current,
      posting_id: @posting.id
    )
    receipt.valid?
    assert_not receipt.errors[:entity_id].any? { |e| e.include?("blank") }
  end

  test "infers entity_id from posting account entity_code" do
    # deposit_bank posting -> bank_gbp (code "110001") -> entity_code "10" ->
    # family_biz entity
    receipt = Receipt.new(
      title: "Auto-entity test",
      receipt_date: Date.current,
      posting_id: @posting.id
    )
    receipt.valid?
    assert_equal entities(:family_biz).id, receipt.entity_id
  end

  # ==================== Defaults ====================

  test "sets default receipt_date to current date" do
    receipt = Receipt.new(title: "Test", entity_id: @entity.id)
    receipt.valid?
    assert_equal Date.current, receipt.receipt_date
  end

  # ==================== Associations ====================

  test "belongs to entity" do
    assert_equal @entity.id, @linked.entity_id
  end

  test "belongs to posting (optional)" do
    assert @linked.posting_id.present?
    assert_nil @unlinked.posting_id
  end

  test "belongs to uploaded_by (optional)" do
    assert_equal admins(:upload_only).id, @uploaded.uploaded_by_id
    assert_nil @linked.uploaded_by_id
  end

  # ==================== Scopes ====================

  test "unlinked scope returns receipts without posting" do
    unlinked = Receipt.unlinked
    assert_includes unlinked, @unlinked
    assert_includes unlinked, @personal
    assert_includes unlinked, @uploaded
    assert_not_includes unlinked, @linked
  end

  test "linked scope returns receipts with posting" do
    linked = Receipt.linked
    assert_includes linked, @linked
    assert_not_includes linked, @unlinked
  end

  test "for_entity scope filters by entity" do
    biz_receipts = Receipt.for_entity(@entity)
    assert_includes biz_receipts, @linked
    assert_includes biz_receipts, @unlinked
    assert_not_includes biz_receipts, @personal
  end

  test "by_date_range scope filters by date" do
    start_date = Date.current - 15.days
    end_date = Date.current
    in_range = Receipt.by_date_range(start_date, end_date)
    assert_includes in_range, @linked
    assert_includes in_range, @personal
  end

  test "recent_first scope orders by date desc" do
    receipts = Receipt.recent_first
    dates = receipts.pluck(:receipt_date)
    assert_equal dates, dates.sort.reverse
  end

  # ==================== link_to_posting! / unlink_from_posting!
  # ====================

  test "link_to_posting! sets posting and clears uploaded_by" do
    @uploaded.link_to_posting!(@posting)
    @uploaded.reload
    assert_equal @posting.id, @uploaded.posting_id
    assert_nil @uploaded.uploaded_by_id
  end

  test "unlink_from_posting! clears posting" do
    @linked.unlink_from_posting!
    @linked.reload
    assert_nil @linked.posting_id
  end

  # ==================== sanitized_title ====================

  test "sanitized_title downcases" do
    @linked.title = "UPPERCASE TITLE"
    assert_equal "uppercase-title", @linked.sanitized_title
  end

  test "sanitized_title replaces umlauts" do
    @linked.title = "Büro Köln Über"
    assert_equal "buero-koeln-ueber", @linked.sanitized_title
  end

  test "sanitized_title removes special characters" do
    @linked.title = "Invoice #123 (2024)"
    assert_equal "invoice-123-2024", @linked.sanitized_title
  end

  test "sanitized_title collapses multiple spaces and dashes" do
    @linked.title = "too   many   spaces"
    assert_equal "too-many-spaces", @linked.sanitized_title
  end

  test "sanitized_title strips leading and trailing dashes" do
    @linked.title = "-leading and trailing-"
    assert_equal "leading-and-trailing", @linked.sanitized_title
  end

  test "sanitized_title truncates to 60 characters" do
    @linked.title = "a" * 100
    assert_equal 60, @linked.sanitized_title.length
  end

  test "sanitized_title returns untitled for blank title" do
    @linked.title = ""
    assert_equal "untitled", @linked.sanitized_title
  end

  test "sanitized_title returns untitled for nil title" do
    @linked.title = nil
    assert_equal "untitled", @linked.sanitized_title
  end

  # ==================== display_filename ====================

  test "display_filename includes date and sanitized title" do
    @linked.title = "Office Supplies"
    @linked.receipt_date = Date.new(2025, 3, 15)
    filename = @linked.display_filename
    assert filename.start_with?("25-03-15-office-supplies")
  end

  test "display_filename uses extension from scan metadata" do
    filename = @linked.display_filename
    assert filename.end_with?(".jpg")
  end

  # ==================== pdf? / image? ====================

  test "image? returns true for image mime type" do
    assert @linked.image?
  end

  test "pdf? returns false for image mime type" do
    assert_not @linked.pdf?
  end

  # ==================== compress_scan_if_oversized ====================

  test "skips compression when scan is in store storage (not a fresh upload)" do
    compress_called = false
    ReceiptUploader.stub(:compress_image, ->(_) { compress_called = true }) do
      @linked.send(:compress_scan_if_oversized)
    end
    refute compress_called
  end

  test "skips compression when cached file is under TARGET_SIZE" do
    receipt = receipt_with_cached_scan(size: 1 * 1024 * 1024, mime_type: "image/jpeg")
    compress_called = false
    ReceiptUploader.stub(:compress_image, ->(_) { compress_called = true }) do
      receipt.send(:compress_scan_if_oversized)
    end
    refute compress_called
  end

  test "calls compress_image for cached image file over TARGET_SIZE" do
    receipt = receipt_with_cached_scan(size: 3 * 1024 * 1024, mime_type: "image/jpeg")
    compressed = Tempfile.new(["compressed", ".jpg"])
    mock_download = Tempfile.new(["dl", ".jpg"])
    compress_called = false

    receipt.scan.stub(:download, mock_download) do
      ReceiptUploader.stub(:compress_image, ->(io) { compress_called = true; compressed }) do
        receipt.scan_attacher.stub(:assign, nil) do
          receipt.send(:compress_scan_if_oversized)
        end
      end
    end

    assert compress_called
  ensure
    compressed&.close rescue nil
    mock_download&.close rescue nil
  end

  test "calls compress_pdf for cached PDF file over TARGET_SIZE" do
    receipt = receipt_with_cached_scan(size: 3 * 1024 * 1024, mime_type: "application/pdf")
    compressed = Tempfile.new(["compressed", ".pdf"])
    mock_download = Tempfile.new(["dl", ".pdf"])
    compress_called = false

    receipt.scan.stub(:download, mock_download) do
      ReceiptUploader.stub(:compress_pdf, ->(io) { compress_called = true; compressed }) do
        receipt.scan_attacher.stub(:assign, nil) do
          receipt.send(:compress_scan_if_oversized)
        end
      end
    end

    assert compress_called
  ensure
    compressed&.close rescue nil
    mock_download&.close rescue nil
  end

  test "skips assign when compression returns nil" do
    receipt = receipt_with_cached_scan(size: 3 * 1024 * 1024, mime_type: "image/jpeg")
    mock_download = Tempfile.new(["dl", ".jpg"])
    assign_called = false

    receipt.scan.stub(:download, mock_download) do
      ReceiptUploader.stub(:compress_image, ->(_) { nil }) do
        receipt.scan_attacher.stub(:assign, ->(_) { assign_called = true }) do
          receipt.send(:compress_scan_if_oversized)
        end
      end
    end

    refute assign_called
  ensure
    mock_download&.close rescue nil
  end

  test "logs error and does not raise when compression raises an exception" do
    receipt = receipt_with_cached_scan(size: 3 * 1024 * 1024, mime_type: "image/jpeg")
    mock_download = Tempfile.new(["dl", ".jpg"])

    receipt.scan.stub(:download, mock_download) do
      ReceiptUploader.stub(:compress_image, ->(_) { raise "boom" }) do
        assert_nothing_raised { receipt.send(:compress_scan_if_oversized) }
      end
    end
  ensure
    mock_download&.close rescue nil
  end

  private

  def receipt_with_cached_scan(size:, mime_type:)
    receipt = Receipt.new
    receipt.scan_attacher.load_data(
      "id" => "test.jpg",
      "storage" => "cache",
      "metadata" => { "size" => size, "mime_type" => mime_type, "filename" => "test.jpg" }
    )
    receipt
  end
end
