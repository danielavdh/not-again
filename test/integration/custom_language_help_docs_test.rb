# frozen_string_literal: true
require "test_helper"

# The gap this closes: Language#easy_manual_textile and friends were collected
# on the form, stored, even shown back on edit — but nothing ever read them at
# render time. WelcomeController#localized_doc and help/_terms_text fell
# straight through to the English static template for any locale outside
# LANGUAGES, every time, silently.
class CustomLanguageHelpDocsTest < ActionDispatch::IntegrationTest
  def release_custom_language(code: "bg", **fields)
    language = Language.create!(code: code, label: "Test", **fields)
    language.release!(by: admins(:sudo))
    language
  end

  test "a released custom language's easy manual shows its own content, not English" do
    release_custom_language(easy_manual_textile: "h1. Как да ползвате приложението\n\np. Uniquely Bulgarian sentence.")

    get easy_manual_path(locale: "bg")

    assert_response :success
    assert_includes response.body, "Uniquely Bulgarian sentence."
    assert_not_includes response.body, "How to use this app" # the English heading
  end

  test "a custom language with a blank easy_manual field still falls back to English" do
    release_custom_language # every content field left blank

    get easy_manual_path(locale: "bg")

    assert_response :success
    assert_includes response.body, "How to use this app"
  end

  test "the legal page renders a released custom language's own content, EU declaration section intact" do
    release_custom_language(legal_textile: "h1. Правно\n\np. Our own uniquely Bulgarian legal text.")

    get legal_path(locale: "bg")

    assert_response :success
    assert_includes response.body, "Our own uniquely Bulgarian legal text."
  end

  test "contact placeholders resolve on the legal page, not left as literal tokens" do
    release_custom_language(legal_textile: "p. Contact us at [EMAIL].")

    get legal_path(locale: "bg")

    assert_response :success
    assert_includes response.body, CONTACT_EMAIL
    assert_not_includes response.body, "[EMAIL]"
  end

  test "terms_show renders a released custom language's own terms" do
    release_custom_language(terms_textile: "p. Our own uniquely Bulgarian terms text.")
    admin = admins(:one)
    admin.update!(terms_agreed_version: nil, terms_agreed_at: nil)
    post session_url(locale: "bg"), params: { username: admin.username, password: "password" }

    get terms_path(locale: "bg")

    assert_response :success
    assert_includes response.body, "Our own uniquely Bulgarian terms text."
  end

  test "an unreleased draft's content never reaches a visitor" do
    Language.create!(code: "bg", label: "Test", easy_manual_textile: "p. Draft, not released.")

    get easy_manual_path(locale: "bg")

    assert_response :not_found
  end

  # The actual bug: custom_doc_html scoped to .released meant sudo's own draft
  # preview silently fell through to English on every help page, even though the
  # routing gate already let them in.
  test "sudo previewing a draft sees the draft's own content, not English" do
    Language.create!(code: "bg", label: "Test",
      easy_manual_textile: "p. Draft Bulgarian text, being reviewed.",
      legal_textile: "p. Draft Bulgarian legal text.")
    sign_in_as(admins(:sudo))

    get easy_manual_path(locale: "bg")
    assert_response :success
    assert_includes response.body, "Draft Bulgarian text, being reviewed."

    get legal_path(locale: "bg")
    assert_response :success
    assert_includes response.body, "Draft Bulgarian legal text."
  end
end
