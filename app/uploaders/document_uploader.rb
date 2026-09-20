# frozen_string_literal: true

# Installation-level documents — currently just the EU declaration of
# conformity, but the model is general on purpose (see Document). Nothing is
# processed: no derivatives, no compression, no thumbnails. What is uploaded
# is what is served.
class DocumentUploader < Shrine
  ALLOWED_TYPES      = %w[application/pdf].freeze
  ALLOWED_EXTENSIONS = %w[pdf].freeze
  # A text-only declaration of conformity is a few hundred KB at most. 1MB
  # would hold that easily, but a REALISTIC case is a scanned page carrying a
  # wet-ink signature — that alone can run past 1MB depending on scan
  # resolution, well before anything else about the file is unreasonable.
  # 5MB, matching the CE-marking reality that most of these get physically
  # signed and scanned rather than digitally signed.
  MAX_SIZE = 5 * 1024 * 1024

  plugin :upload_options, store: ->(io, context) {
    { content_disposition: "inline" }
  }

  Attacher.validate do
    validate_max_size MAX_SIZE, message: "must be less than 5MB"
    validate_mime_type ALLOWED_TYPES, message: "must be a PDF"
    validate_extension ALLOWED_EXTENSIONS, message: "must be .pdf"
  end
end
