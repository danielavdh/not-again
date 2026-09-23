# frozen_string_literal: true

require "test_helper"

class ReceiptUploaderTest < ActiveSupport::TestCase
  FIXTURE_IMAGE = Rails.root.join("test/fixtures/files/test_receipt.jpg")

  # ==================== Constants ====================

  test "MAX_SIZE is 20MB" do
    assert_equal 20 * 1024 * 1024, ReceiptUploader::MAX_SIZE
  end

  test "TARGET_SIZE is 2MB" do
    assert_equal 2 * 1024 * 1024, ReceiptUploader::TARGET_SIZE
  end

  # ==================== compress_image ====================

  test "compress_image returns a Tempfile for a valid image" do
    File.open(FIXTURE_IMAGE, "rb") do |io|
      result = ReceiptUploader.compress_image(io)
      assert_instance_of Tempfile, result
      assert result.size > 0
    end
  end

  test "compress_image output is a JPEG" do
    File.open(FIXTURE_IMAGE, "rb") do |io|
      result = ReceiptUploader.compress_image(io)
      # JPEG magic bytes: FF D8
      result.rewind
      header = result.read(2).bytes
      assert_equal [0xFF, 0xD8], header
    end
  end

  test "compress_image returns nil and does not raise on error" do
    bad_io = StringIO.new("this is not an image")
    assert_nil ReceiptUploader.compress_image(bad_io)
  end

  # ==================== compress_pdf ====================

  test "compress_pdf returns nil and does not raise on error" do
    bad_io = StringIO.new("this is not a pdf")
    # Ghostscript will fail on bad input; method should return nil
    assert_nil ReceiptUploader.compress_pdf(bad_io)
  end

  # ==================== derivatives ====================

  FIXTURE_PDF = Rails.root.join("test/fixtures/files/sample.pdf")

  test "a valid PDF gets a thumbnail and a preview" do
    receipt = Receipt.new(title: "invoice", receipt_date: Date.current, entity_id: entities(:family_biz).id)
    receipt.scan = File.open(FIXTURE_PDF, "rb")
    receipt.save!
    receipt.scan_attacher.create_derivatives

    assert_equal %i[thumbnail preview].sort, receipt.scan_derivatives.keys.sort
  end

  # The image path, not just the PDF one — and asserting the derivative is a
  # real, readable image of the right size, because the derivatives block
  # rescues everything: a thumbnail that silently never gets built looks exactly
  # like a passing test if you only count the keys.
  test "a photographed receipt gets a thumbnail and a preview that are real images" do
    receipt = Receipt.new(title: "photo", receipt_date: Date.current, entity_id: entities(:family_biz).id)
    receipt.scan = File.open(Rails.root.join("test/fixtures/files/test_receipt.jpg"), "rb")
    receipt.save!
    receipt.scan_attacher.create_derivatives

    assert_equal %i[thumbnail preview].sort, receipt.scan_derivatives.keys.sort

    thumbnail = receipt.scan_derivatives[:thumbnail]
    assert_equal "image/jpeg", thumbnail.mime_type
    assert_operator thumbnail.size, :>, 0
    assert_operator [ thumbnail.width, thumbnail.height ].max, :<=, 200,
      "the thumbnail is capped at 200px on its long side"
  end

  # A receipt PDF Ghostscript cannot render — encrypted, malformed, PDF 2.0 —
  # must NOT lose the upload: the derivative step returns nothing, promotion
  # still moves the original into permanent storage, and the preview falls back
  # to the placeholder SVG.
  test "a PDF whose thumbnail cannot be built still promotes, with a fallback preview" do
    receipt = Receipt.new(title: "awkward", receipt_date: Date.current, entity_id: entities(:family_biz).id)
    receipt.scan = File.open(FIXTURE_PDF, "rb")
    receipt.save!

    boom = ->(*) { raise "Ghostscript: Unrecoverable error, exit code 1" }
    ImageProcessing::MiniMagick.stub(:source, boom) do
      assert_nothing_raised { receipt.scan_attacher.atomic_promote }
    end

    assert_empty receipt.reload.scan_derivatives
    assert_equal "store", receipt.scan.storage_key.to_s, "the original must be promoted, not stranded in cache"
    assert_equal "/fallback/receipt_preview.svg", receipt.scan_url(:preview)
  end
end
