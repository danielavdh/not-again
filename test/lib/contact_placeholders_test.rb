# frozen_string_literal: true
require "test_helper"

class ContactPlaceholdersTest < ActiveSupport::TestCase
  test "replaces every token with the installation's real contact details" do
    text = "Contact us at [EMAIL]. [SERVICE NAME] is run by [TRADING NAME] " \
           "([LEGAL NAME]), [STREET], [CITY], [COUNTRY], at [WEBSITE]."

    filled = ContactPlaceholders.fill(text)

    assert_includes filled, CONTACT_EMAIL
    assert_includes filled, SERVICE_NAME
    assert_includes filled, CONTACT_TRADING
    assert_includes filled, CONTACT_NAME
    assert_includes filled, CONTACT_STREET
    assert_includes filled, CONTACT_CITY
    assert_includes filled, CONTACT_COUNTRY
    refute_match(/\[[A-Z ]+\]/, filled, "no bracket token should survive")
  end

  test "text with no tokens passes through unchanged" do
    assert_equal "Nothing to fill in here.", ContactPlaceholders.fill("Nothing to fill in here.")
  end

  test "blank input stays blank, never raises" do
    assert_nil ContactPlaceholders.fill(nil)
    assert_equal "", ContactPlaceholders.fill("")
  end

  test "a token can appear more than once and every occurrence is filled" do
    filled = ContactPlaceholders.fill("[EMAIL] and again [EMAIL]")

    assert_equal "#{CONTACT_EMAIL} and again #{CONTACT_EMAIL}", filled
  end
end
