# frozen_string_literal: true
require "test_helper"

class EntityTaxTest < ActiveSupport::TestCase
  # An entity has no country of its own. A scheme names one, so a business
  # filing in two places simply carries two schemes.
  test "an entity needs no country at all" do
    e = Entity.new(code: "99", name: "T")
    assert e.valid?
  end

  test "a scheme from another country is accepted" do
    e = Entity.new(code: "99", name: "T", tax_schemes: ["de_euer"])
    assert e.valid?, e.errors.full_messages.to_sentence
  end

  test "schemes from two countries are accepted together" do
    e = Entity.new(code: "99", name: "T", tax_schemes: %w[gb_self_employment de_vermietung])
    assert e.valid?, e.errors.full_messages.to_sentence
  end

  test "a scheme that is not in the catalogue is rejected" do
    e = Entity.new(code: "99", name: "T", tax_schemes: ["no_such_scheme"])
    refute e.valid?
    assert e.errors[:tax_schemes].any?
  end

  test "schemes no longer require a country" do
    e = Entity.new(code: "99", name: "T", tax_schemes: ["gb_self_employment"])
    assert e.valid?, e.errors.full_messages.to_sentence
  end

  test "available_tax_schemes offers every catalogued scheme" do
    assert_equal TaxSchemeConfig.all_schemes, Entity.new.available_tax_schemes
  end
end
