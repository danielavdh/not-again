# frozen_string_literal: true

require "test_helper"

# The upload path for installation-level documents. See self-hosting-legal.md
# and Document.
class DocumentsUploadTest < ActionDispatch::IntegrationTest
  def pdf
    fixture_file_upload("sample.pdf", "application/pdf")
  end

  def sign_in(admin)
    post session_url(locale: :en), params: { username: admin.username, password: "password" }
  end

  test "sudo can upload the EU declaration, and it becomes publicly visible" do
    sign_in(admins(:sudo))

    post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: pdf }
    assert_redirected_to legal_path(locale: :en)

    delete session_url(locale: :en) # a logged-out visitor should see it too
    get legal_url(locale: :en)

    assert_includes response.body, "Download the EU Declaration of Conformity"
  end

  test "the upload form itself is never shown to a logged-out visitor" do
    get legal_url(locale: :en)

    assert_not_includes response.body, "documents_path"
  end

  test "the upload form is shown to sudo, and to nobody else" do
    marker = 'name="kind"' # the form's own hidden field — nothing else on the page can say this

    get legal_url(locale: :en)
    assert_not_includes response.body, marker

    sign_in(admins(:one)) # full_access, not sudo
    get legal_url(locale: :en)
    assert_not_includes response.body, marker
    delete session_url(locale: :en)

    sign_in(admins(:sudo))
    get legal_url(locale: :en)
    assert_includes response.body, marker
  end

  # ⚠️ ONE row per kind, always — a second upload REPLACES, it does not
  # accumulate. This is what the unique index on :kind exists to guarantee.
  test "uploading again replaces the document rather than creating a second one" do
    sign_in(admins(:sudo))

    assert_difference("Document.count", 1) do
      post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: pdf }
    end

    assert_no_difference("Document.count") do
      post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: pdf }
    end
  end

  test "a second upload records who replaced it, not just who uploaded it first" do
    sign_in(admins(:sudo))
    post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: pdf }

    delete session_url(locale: :en)
    sign_in(admins(:two))
    admins(:two).update!(sudo: true)
    post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: pdf }

    document = Document.find_by(kind: "eu_declaration_of_conformity")
    assert_equal admins(:two).id, document.uploaded_by_id
  end

  test "a non-sudo admin cannot upload, even with full access" do
    sign_in(admins(:one))

    assert_no_difference("Document.count") do
      post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: pdf }
    end
  end

  test "a logged-out visitor cannot upload" do
    assert_no_difference("Document.count") do
      post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: pdf }
    end
  end

  test "a non-PDF is rejected" do
    sign_in(admins(:sudo))
    text = Rack::Test::UploadedFile.new(StringIO.new("not a pdf"), "text/plain", original_filename: "evil.txt")

    assert_no_difference("Document.count") do
      post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: text }
    end
  end

  test "a PDF with a .txt extension is still rejected — extension and mime type are both checked" do
    sign_in(admins(:sudo))
    disguised = Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/sample.pdf"), "application/pdf", original_filename: "evil.txt"
    )

    assert_no_difference("Document.count") do
      post documents_url(locale: :en), params: { kind: "eu_declaration_of_conformity", doc: disguised }
    end
  end
  # THE REGRESSION. String-presence checks do not catch a block landing in the
  # wrong PLACE on the page, only that it exists somewhere. This caught the
  # block landing between the intro and "Who we are" instead of near Impressum,
  # while every other test in this file was green.
  test "the download link sits after exchange rates and before impressum; the upload form after the final back link" do
    Document.create!(kind: "eu_declaration_of_conformity")
    sign_in(admins(:sudo))
    get legal_url(locale: :en)
    body = response.body

    exchange_pos     = body.index("Exchange rate data")
    download_pos     = body.index("Download the EU Declaration")
    impressum_pos    = body.index('id="impressum"')
    last_back_pos    = body.rindex("Back to Homepage")
    upload_form_pos  = body.index('name="kind"')

    assert exchange_pos && download_pos && impressum_pos && last_back_pos && upload_form_pos,
           "one of the expected markers is missing from the page entirely"
    assert_operator exchange_pos, :<, download_pos
    assert_operator download_pos, :<, impressum_pos
    assert_operator upload_form_pos, :>, last_back_pos
  end
end
