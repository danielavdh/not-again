# frozen_string_literal: true

require "test_helper"

# Nothing else renders these. They are eight manual files plus four legal pages
# of hand-written HTML, reached by a route that silently falls back to English,
# so a renamed template, a broken tag or a missing key reaches a reader rather
# than a test. The ReceiptsController MissingTemplate of 2026-10-12 was the same
# shape: a page with one template, 500ing in production, covered by nothing.
class HelpPagesTest < ActionDispatch::IntegrationTest
  PAGES   = %w[legal easy_manual pro_manual].freeze
  LOCALES = %w[en de es nl].freeze

  def visit(page, locale)
    get public_send("#{page}_path", locale: locale)
  end

  def each_page
    PAGES.product(LOCALES) { |page, locale| yield page, locale }
  end

  test "every help page is readable in every language" do
    each_page do |page, locale|
      visit page, locale

      assert_response :success, "#{page} in #{locale}"
      assert_equal "text/html", response.media_type, "#{page} in #{locale}"
    end
  end

  # A missing key renders as a visible span rather than raising, so a reader
  # sees the key and nothing else notices.
  test "no help page shows a reader a missing translation" do
    each_page do |page, locale|
      visit page, locale

      assert_no_match(/translation[ _]missing/i, response.body, "#{page} in #{locale}")
    end
  end

  # WelcomeController#localized_doc falls back to the English template when the
  # localised one is not found, so a renamed or deleted file serves English to
  # someone who asked for Dutch, with no error anywhere.
  #
  # Asserted on the file rather than the response on purpose: comparing bodies
  # does NOT catch it. The shared back-button partial is translated, so a Dutch
  # request for the English template still differs from the English one — that
  # version of this test passed with pro_manual_nl.html.erb deleted.
  test "a reader who asks for their own language has a page in it" do
    each_page do |page, locale|
      template = Rails.root.join("app/views/help/#{page}_#{locale}.html.erb")

      assert File.exist?(template),
             "#{page} in #{locale} would silently serve English: #{template.basename} is missing"
    end
  end

  # A table of contents that points at nothing is the failure mode of editing
  # these by hand: the link is added, the section is not.
  test "every manual's table of contents lands on a section that exists" do
    each_page do |page, locale|
      visit page, locale
      body = response.body

      wanted = body.scan(/href="#([\w-]+)"/).flatten.uniq
      present = body.scan(/id="([\w-]+)"/).flatten.to_set
      missing = wanted.reject { |anchor| present.include?(anchor) }

      assert_empty missing, "#{page} in #{locale} links to ##{missing.join(', #')} with no such section"
    end
  end

  # Installation management, not bookkeeping. A bookkeeper reading it would be
  # told how to do things their account cannot do.
  test "the pro manual's installation chapter reaches sudo and nobody else" do
    visit "pro_manual", "en"
    assert_no_match(/id="sudo"/, response.body, "a signed-out visitor")

    sign_in_as(admins(:two))
    visit "pro_manual", "en"
    assert_no_match(/id="sudo"/, response.body, "a full-access bookkeeper")

    sign_in_as(admins(:sudo))
    visit "pro_manual", "en"
    assert_match(/id="sudo"/, response.body, "sudo has to be able to read it")
  end
end
