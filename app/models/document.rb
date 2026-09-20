# frozen_string_literal: true

# Installation-level documents. Currently the EU declaration of conformity
# (see self-hosting-legal.md), but deliberately general — there is always
# something to upload eventually. One row per kind, ever: uploading again
# replaces the file rather than adding a second row for the same kind.
class Document < ApplicationRecord
  include DocumentUploader::Attachment(:doc)

  belongs_to :uploaded_by, class_name: "Admin", optional: true

  validates :kind, presence: true, uniqueness: true

  EU_DECLARATION_OF_CONFORMITY = "eu_declaration_of_conformity"
end
