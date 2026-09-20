# frozen_string_literal: true

require "test_helper"

class DocumentTest < ActiveSupport::TestCase
  test "requires a kind" do
    doc = Document.new
    assert_not doc.valid?
  end

  test "kind must be unique — one document per kind, ever" do
    Document.create!(kind: "eu_declaration_of_conformity")

    duplicate = Document.new(kind: "eu_declaration_of_conformity")
    assert_not duplicate.valid?
  end

  test "different kinds coexist fine" do
    Document.create!(kind: "eu_declaration_of_conformity")
    other = Document.new(kind: "something_else")

    assert other.valid?
  end

  # Same lesson as sign_in_events and (briefly) terms_agreements: on_delete
  # must not be the default RESTRICT, or deleting the uploading admin breaks.
  test "the uploading admin can still be deleted" do
    admin = Admin.create!(username: "uploader_leaves", password: "password123", email_address: "leaves@example.org")
    Document.create!(kind: "eu_declaration_of_conformity", uploaded_by: admin)

    assert_nothing_raised { admin.destroy! }
  end

  test "deleting the uploading admin keeps the document, just loses the attribution" do
    admin = Admin.create!(username: "uploader_leaves", password: "password123", email_address: "leaves@example.org")
    doc = Document.create!(kind: "eu_declaration_of_conformity", uploaded_by: admin)

    admin.destroy!
    doc.reload

    assert_nil doc.uploaded_by_id
  end
end
