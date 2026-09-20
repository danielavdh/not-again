# frozen_string_literal: true

require "test_helper"

class EntitiesHelperTest < ActionView::TestCase
  # The authority follows the SCHEME, not the entity's country — that is what
  # lets one entity file in more than one country.
  test "submission_authorities names the authority behind each filing scheme" do
    entity = entities(:daughter)
    entity.tax_schemes = ["gb_self_employment"]

    authorities = submission_authorities(entity)
    assert_equal 1, authorities.size
    assert_equal "HMRC",          authorities.first[:name]
    assert_equal "gb_connection", authorities.first[:anchor]
  end

  test "submission_authorities is empty when no scheme can be filed" do
    entity = entities(:daughter)
    entity.tax_schemes = []
    assert_empty submission_authorities(entity)

    # de_euer is catalogued but has no filing connector — tagging and export
    # only
    entity.tax_schemes = ["de_euer"]
    assert_empty submission_authorities(entity)
  end

  test "the authority comes from the scheme, wherever the entity is" do
    entity = entities(:daughter)
    entity.tax_schemes = ["gb_self_employment"]

    assert_equal ["HMRC"], submission_authorities(entity).map { |a| a[:name] }
  end

  # One entry per AUTHORITY, not per scheme. Both filing-capable schemes are
  # HMRC today, so this is the deduplication case; a second country's connector
  # would add a second entry.
  test "several filing schemes under one authority produce a single entry" do
    entity = entities(:daughter)
    entity.tax_schemes = %w[gb_self_employment gb_property]
    assert_equal [ { name: "HMRC", connector: "hmrc_mtd", anchor: "gb_connection" } ],
                 submission_authorities(entity)
  end

  # Views must branch on the CONNECTOR. Gating on the display name meant
  # renaming `authority:` in a catalogue header silently hid the NINO and
  # business-id fields — no error, just a form missing three inputs.
  #
  # This blew up in the browser rather than the suite: I18n RESERVES :format,
  # along with :default, :scope and :locale, and raises rather than
  # interpolating. Rendering the options is the only thing that catches it.
  test "the accountant-export options render without a reserved interpolation key" do
    options = accountant_export_options
    assert options.any?, "there should be at least one format to offer"
    options.each do |label, slug|
      assert label.present?, "#{slug} rendered no label"
      refute_match(/translation missing/i, label)
    end
  end

  test "files_via? answers by connector, not by the authority's label" do
    entity = entities(:daughter)
    entity.tax_schemes = %w[gb_self_employment]
    assert files_via?(entity, "hmrc_mtd")
    refute files_via?(entity, "elster")
  end

  test "a scheme with no connector cannot be filed through anything" do
    entity = entities(:daughter)
    entity.tax_schemes = %w[de_vermietung]
    assert_empty submission_authorities(entity)
    refute files_via?(entity, "hmrc_mtd")
  end
end
