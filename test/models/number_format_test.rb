# frozen_string_literal: true
require "test_helper"

class NumberFormatTest < ActiveSupport::TestCase
  test "every FORMATS row is a full triple and every sample round-trips" do
    NumberFormat::FORMATS.each do |slug, f|
      assert f[:delimiter] && f[:separator] && f[:symbol], "#{slug} is incomplete"
      # the ¤ sample, with a real symbol in, must parse back to 1234.56
      shown = NumberFormat.sample(f).sub("¤", "€")
      assert_equal 123_456, CurrencyConfig.parse_to_cents(shown), "#{slug} sample #{shown.inspect}"
    end
  end

  test "the menu is [sample, slug] pairs, one per format, ¤ for the symbol" do
    menu = NumberFormat.menu
    assert_equal NumberFormat::FORMATS.size, menu.size
    menu.each do |sample, slug|
      assert_includes sample, "¤"
      assert NumberFormat::FORMATS.key?(slug)
    end
    assert_includes menu, ["¤ 1'234.56", "ch"]
    assert_includes menu, ["1 234,56 ¤", "fr"]
  end

  test "resolve: an explicit slug wins, blank falls to the language default" do
    assert_equal NumberFormat::FORMATS["ch"], NumberFormat.resolve("ch", :de)
    assert_equal NumberFormat::FORMATS["de"], NumberFormat.resolve(nil, :de)
    assert_equal NumberFormat::FORMATS["de"], NumberFormat.resolve("",  :es)
    assert_equal NumberFormat::FORMATS["at"], NumberFormat.resolve(nil, :nl)
    assert_equal NumberFormat::FORMATS["uk"], NumberFormat.resolve(nil, :en)
  end

  test "resolve: an unknown slug falls to the language default rather than raising" do
    assert_equal NumberFormat::FORMATS["de"], NumberFormat.resolve("gone", :de)
  end

  test "a language with no DEFAULT_FOR reads its own rails-i18n block" do
    # nl HAS a default; drop it for the length of the test to hit the fallback.
    original = NumberFormat::DEFAULT_FOR
    NumberFormat.send(:remove_const, :DEFAULT_FOR)
    NumberFormat.const_set(:DEFAULT_FOR, { "en" => "uk" }.freeze)

    r = NumberFormat.resolve(nil, :nl)
    assert_equal ",", r[:separator]
    assert_equal ".", r[:delimiter]
    assert_equal "%u %n", r[:symbol]   # nl in rails-i18n: symbol before, spaced
  ensure
    NumberFormat.send(:remove_const, :DEFAULT_FOR)
    NumberFormat.const_set(:DEFAULT_FOR, original)
  end

  test "valid? accepts blank and known slugs only" do
    assert NumberFormat.valid?(nil)
    assert NumberFormat.valid?("")
    assert NumberFormat.valid?("ch")
    assert_not NumberFormat.valid?("nope")
  end

  test "Admin refuses a preferred_number_format that is not a known slug" do
    admin = admins(:one)
    admin.preferred_number_format = "de"
    assert admin.valid?
    admin.preferred_number_format = ""
    assert admin.valid?, "blank means follow the language"
    admin.preferred_number_format = "martian"
    assert_not admin.valid?
    assert_includes admin.errors[:preferred_number_format], "is not included in the list"
  end

  test "js_config is just separator + delimiter" do
    assert_equal({ separator: ".", delimiter: "'" }, NumberFormat.js_config("ch"))
  end

  # What CurrencyConfig.format_cents produces under each format must parse
  # straight back — the whole point is that the screen and the stored value
  # agree, whatever shape the admin picked.
  test "every format round-trips through format_cents and parse_to_cents" do
    NumberFormat::FORMATS.each_key do |slug|
      Current.number_format = slug
      [123_456, -123_456, 5, 100_000_00, 99].each do |cents|
        %w[GBP EUR CHF].each do |code|
          shown = CurrencyConfig.format_cents(cents, code)
          assert_equal cents, CurrencyConfig.parse_to_cents(shown),
                       "#{slug} / #{code} / #{cents}: #{shown.inspect} did not survive"
        end
      end
    end
  ensure
    Current.number_format = nil
  end
end
