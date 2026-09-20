require "image_processing/mini_magick"
require "open3"

class ReceiptUploader < Shrine
  ALLOWED_TYPES = %w[
    image/jpeg image/jpg image/png image/heic image/heif
    application/pdf
  ].freeze
  ALLOWED_EXTENSIONS = %w[jpg jpeg png heic heif pdf].freeze
  MAX_SIZE    = 20 * 1024 * 1024 # 20 MB — hard rejection limit
  TARGET_SIZE =  2 * 1024 * 1024 #  2 MB — files above this are compressed before storage

  plugin :derivatives, create_on_promote: true
  plugin :store_dimensions
  plugin :default_url
  plugin :upload_options, store: ->(io, context) {
    { content_disposition: "inline" }
  }

  Attacher.validate do
    validate_max_size MAX_SIZE, message: "must be less than 20MB"
    validate_mime_type ALLOWED_TYPES, message: "must be an image (JPG, PNG, HEIC) or PDF"
    validate_extension ALLOWED_EXTENSIONS, message: "must be .jpg, .png, .heic, or .pdf"
  end

  Attacher.derivatives do |original|
    first_page = nil

    if self.file.mime_type == "application/pdf"
      # PDF: render the first page to an image, then thumbnail it.
      # ImageMagick reads PDFs through Ghostscript — page: 0 = first page.
      first_page = ImageProcessing::MiniMagick
        .source(original)
        .loader(page: 0)
        .convert("png")
        .call

      {
        thumbnail: ImageProcessing::MiniMagick.source(first_page).resize_to_limit!(200, 200),
        preview:   ImageProcessing::MiniMagick.source(first_page).resize_to_limit!(800, 800)
      }
    else
      # Image: auto-orient and thumbnail.
      {
        thumbnail: ImageProcessing::MiniMagick.source(original)
                     .auto_orient.convert("jpg").resize_to_limit!(200, 200),
        preview:   ImageProcessing::MiniMagick.source(original)
                     .auto_orient.convert("jpg").resize_to_limit!(800, 800)
      }
    end
  rescue => e
    # A thumbnail is cosmetic; the receipt itself is not. A PDF Ghostscript
    # cannot render (encrypted, malformed, PDF 2.0 features…) or an image
    # ImageMagick chokes on must NOT fail promotion — that would strand the
    # original in the cache store and lose it. Log it, ship no derivatives,
    # and Attacher.default_url serves the fallback SVG in the preview's place.
    Rails.logger.error "ReceiptUploader: no derivatives for #{self.file.mime_type} — #{e.message}"
    Rails.logger.error e.backtrace.first(3).join("\n")
    {}
  ensure
    first_page.delete if first_page.respond_to?(:delete)
  end

  Attacher.default_url do |derivative: nil, **|
    "/fallback/receipt_#{derivative}.svg" if derivative
  end

  def generate_location(io, context)
    record = context[:record]
    return super unless record.is_a?(Receipt)

    date_prefix = record.receipt_date&.strftime("%y-%m-%d") || "00-00-00"
    ext = File.extname(extract_filename(io) || "file").downcase
    filename = "#{date_prefix}-#{record.sanitized_title}#{ext}"

    # Let the partition plugin build the path, then swap the filename
    location = super
    location.sub(/[^\/]+\z/, filename)
  end

  def self.compress_image(io)
    ImageProcessing::MiniMagick
      .source(io)
      .auto_orient
      .convert("jpg")
      .saver(quality: 80)
      .resize_to_limit!(2000, 2000)
  rescue => e
    Rails.logger.error "ReceiptUploader image compression failed: #{e.message}"
    nil
  end

  def self.compress_pdf(io)
    input_path = io.respond_to?(:path) ? io.path : write_to_tempfile(io, ".pdf").path
    output = Tempfile.new(["receipt_compressed", ".pdf"])
    output.close

    # capture3, not system: Ghostscript writes its diagnostics straight to the
    # terminal, so a failure here used to dump a wall of PostScript stack trace
    # into the test output and into the container's stderr — alarming, and
    # detached from any context saying which receipt it was. Captured, the same
    # text becomes one log line we can actually act on.
    %w[printer ebook].each do |preset|
      _out, err, status = Open3.capture3(
        "gs", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.4",
        "-dPDFSETTINGS=/#{preset}", "-dNOPAUSE", "-dQUIET", "-dBATCH",
        "-sOutputFile=#{output.path}", input_path
      )
      unless status.success?
        Rails.logger.error(
          "ReceiptUploader: Ghostscript failed on preset #{preset} — #{err.to_s.strip.lines.first}"
        )
        return nil
      end
      output.open("rb")
      return output if output.size <= TARGET_SIZE
      output.close
    end

    output.open("rb")
    output
  rescue => e
    Rails.logger.error "ReceiptUploader PDF compression failed: #{e.message}"
    nil
  end

  def self.write_to_tempfile(io, ext)
    tmp = Tempfile.new(["receipt_input", ext])
    tmp.binmode
    io.rewind if io.respond_to?(:rewind)
    tmp.write(io.read)
    tmp.rewind
    tmp
  end

  private

  def self.pdf?(mime_type)
    mime_type.to_s == "application/pdf"
  end

  def pdf?(mime_type)
    self.class.pdf?(mime_type)
  end

  def extract_filename(io)
    if io.respond_to?(:original_filename)
      io.original_filename
    elsif io.respond_to?(:path)
      File.basename(io.path)
    end
  end
end
