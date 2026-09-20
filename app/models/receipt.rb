# frozen_string_literal: true

class Receipt < ApplicationRecord

  include ReceiptUploader::Attachment(:scan)

  belongs_to :entity,
             class_name: "Entity",
             foreign_key: :entity_id,
             optional: true
  belongs_to :posting,
             class_name: "Posting",
             foreign_key: :posting_id,
             optional: true
  belongs_to :uploaded_by,
             class_name: "Admin",
             optional: true

  before_validation :set_defaults_from_context, if: :new_record?
  before_save :compress_scan_if_oversized
  validates :title, presence: true, length: { maximum: 100 }
  validates :receipt_date, presence: true
  validates :scan, presence: true, on: :create
  validates :entity_id, presence: true, unless: :nested_via_posting?

  scope :unlinked, -> { where(posting_id: nil) }
  scope :linked, -> { where.not(posting_id: nil) }
  scope :for_entity, ->(entity) { where(entity_id: entity.id) }
  scope :by_date_range, ->(start_date, end_date) { where(receipt_date: start_date..end_date) }
  scope :recent_first, -> { order(receipt_date: :desc, created_at: :desc) }

  before_validation :set_default_receipt_date, on: :create

  def link_to_posting!(posting)
    update!(posting_id: posting.id, uploaded_by_id: nil)
  end

  def unlink_from_posting!
    update!(posting: nil)
  end

  def sanitized_title
    return "untitled" if title.blank?

    title
      .downcase
      .gsub(/[äöüÄÖÜ]/) { |m| { "ä" => "ae", "ö" => "oe", "ü" => "ue" }[m.downcase] || m }
      .gsub(/[^a-z0-9\s-]/, "")
      .gsub(/[\s]+/, "-")
      .gsub(/-{2,}/, "-")
      .gsub(/\A-|-\z/, "")
      .truncate(60, omission: "")
  end

  def display_filename
    ext = scan&.metadata&.dig("filename")&.then { |f| File.extname(f) } || ".jpg"
    date_str = receipt_date&.strftime("%y-%m-%d") || "00-00-00"
    "#{date_str}-#{sanitized_title}#{ext}"
  end

  def pdf?
    scan&.mime_type&.to_s == "application/pdf"
  end

  def image?
    scan&.mime_type&.to_s&.start_with?("image/")
  end

  def thumbnail_url
    scan_url(:thumbnail)
  end

  def preview_url
    scan_url(:preview)
  end

  def original_url
    scan&.url
  end

  private

  def set_defaults_from_context
    self.uploaded_by ||= Current.admin
    if entity_id.blank?
      entity_code = posting&.account&.entity_code
      self.entity_id = Entity.find_by(code: entity_code)&.id if entity_code
    end
  end

  def set_default_receipt_date
    self.receipt_date ||= Date.current
  end

  def nested_via_posting?
    posting_id.present? || (posting.present? && posting.new_record?)
  end

  def compress_scan_if_oversized
    return unless scan_attacher.cached? && scan
    return if scan.size.to_i <= ReceiptUploader::TARGET_SIZE

    mime       = scan.mime_type
    downloaded = scan.download
    compressed = nil

    compressed = if mime == "application/pdf"
      ReceiptUploader.compress_pdf(downloaded)
    else
      ReceiptUploader.compress_image(downloaded)
    end

    scan_attacher.assign(compressed) if compressed
  rescue => e
    Rails.logger.error "Receipt scan compression error (id=#{id}): #{e.message}"
  ensure
    downloaded&.close rescue nil
    compressed&.close rescue nil
  end
end