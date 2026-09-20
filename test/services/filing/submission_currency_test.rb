# frozen_string_literal: true
require "test_helper"

# The shared filing views must not name an authority OR its money.
#
# _submission.html.erb and _preview.html.erb sit in the GENERIC
# app/views/filing/ directory, next to the authority-specific hmrc_mtd/
# subdirectory, and formatted every amount as the literal "GBP" in eleven
# places. A German filing an EÜR saw euro figures labelled £, and a Swiss one
# saw francs labelled £. Nothing failed; the numbers were right and the symbol
# was a lie.
#
# The fix was not new machinery — every scheme's catalogue file already declares
# `currency:`, and TaxSchemeConfig.currency_for already read it. It was never
# threaded to the views.
class Filing::SubmissionCurrencyTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:family_biz)
  end

  def filing(scheme)
    Filing::Base.new(entity: @entity, scheme: scheme, admin: admins(:sudo))
  end

  test "each scheme files in the currency its catalogue declares" do
    expected = {
      "gb_self_employment" => "GBP",
      "gb_property"     => "GBP",
      "de_euer"            => "EUR",
      "de_vermietung"      => "EUR",
      "ch_selbst"          => "CHF"
    }

    expected.each do |scheme, currency|
      assert_equal currency, filing(scheme).submission_currency,
                   "#{scheme} must file in #{currency}"
    end
  end

  # Belongs on Base, not on a connector, for the same reason panel_partial does:
  # reading the catalogue is generic, and a second authority must inherit it
  # rather than repeat it.
  test "it is generic, not the connector's" do
    assert Filing::Base.method_defined?(:submission_currency)
    assert_equal Filing::Base,
                 Filing::HmrcMtd.instance_method(:submission_currency).owner,
                 "HmrcMtd must inherit this, not define its own"
  end

  # No fallback currency, deliberately. A scheme that forgets to declare one
  # renders with NO symbol, which is visible. A `|| "GBP"` is a confidently
  # wrong symbol, which is not.
  test "an undeclared currency is nil, never a guess" do
    assert_nil filing("no_such_scheme").submission_currency
    assert_equal "", CurrencyConfig.symbol_for(nil)
  end

  # The structural guard. Catching the next one by reading the file is cheaper
  # than catching it in a real submission to a tax authority.
  test "no generic filing view hardcodes a currency" do
    generic = Dir[Rails.root.join("app/views/filing/*.erb")]
    assert generic.any?, "expected generic filing views to exist"

    codes = CurrencyConfig.available
    generic.each do |path|
      body = File.read(path)
                 .gsub(/<%#.*?%>/m, "")   # comments may name the old bug
      codes.each do |code|
        assert_no_match(/["']#{code}["']/, body,
                        "#{File.basename(path)} names #{code}. The currency comes " \
                        "from the scheme, not from a shared template.")
      end
    end
  end
end
