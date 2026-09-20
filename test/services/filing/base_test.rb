# frozen_string_literal: true
require "test_helper"

# The connector registry. Adding a country's submission should be a file plus
# one word in CONNECTORS — never a `case` somewhere that has to be found first.
class Filing::BaseTest < ActiveSupport::TestCase
  setup do
    @entity = entities(:family_biz)
  end

  def build(connector)
    Filing::Base.for(connector, entity: @entity, scheme: "gb_self_employment", admin: admins(:sudo))
  end

  test "resolves a registered connector name to its class" do
    assert_instance_of Filing::HmrcMtd, build("hmrc_mtd")
  end

  test "every registered connector actually resolves" do
    Filing::Base::CONNECTORS.each do |connector|
      klass = Filing::Base.connector_class(connector)
      assert klass, "#{connector} is in CONNECTORS but no class answers to it"
      assert_operator klass, :<, Filing::Base
    end
  end

  # The class name IS the connector name, so the class and the catalogue header
  # cannot drift apart in code.
  test "a connector derives its name from its own class" do
    assert_equal "hmrc_mtd", Filing::HmrcMtd.connector
  end

  test "an unknown connector is not registered and cannot be built" do
    refute Filing::Base.registered?("elster")
    assert_nil Filing::Base.connector_class("elster")
    assert_raises(ArgumentError) { build("elster") }
  end

  test "nil and blank are handled rather than resolving to something" do
    refute Filing::Base.registered?(nil)
    refute Filing::Base.registered?("")
    assert_nil Filing::Base.connector_class(nil)
    assert_raises(ArgumentError) { build(nil) }
  end

  # A connector name is turned into a constant, so it must not be a route to
  # naming any class that happens to exist — neither a neighbour in this module
  # nor, via const_get's ancestor fallback to Object, a top-level one.
  test "a name outside the registry cannot reach an arbitrary class" do
    refute Filing::Base.registered?("storage")
    assert_nil Filing::Base.connector_class("storage")
    assert_nil Filing::Base.connector_class("base")
    assert_nil Filing::Base.connector_class("string")
  end

  test "even inside the registry the lookup never reaches a top-level constant" do
    with_connectors(%w[string]) do
      assert_nil Filing::Base.connector_class("string"),
                 "const_get must not fall back to Object and return ::String"
    end
  end

  def with_connectors(list)
    original = Filing::Base::CONNECTORS
    Filing::Base.send(:remove_const, :CONNECTORS)
    Filing::Base.const_set(:CONNECTORS, list.freeze)
    yield
  ensure
    Filing::Base.send(:remove_const, :CONNECTORS)
    Filing::Base.const_set(:CONNECTORS, original)
  end

  # Every catalogue that declares a connector must name one we have built, or
  # the entity is offered a connection that goes nowhere.
  test "every connector declared in a catalogue has a class" do
    declared = TaxSchemeConfig.all_schemes
                                   .filter_map { |s| TaxSchemeConfig.connector_for(s) }
                                   .uniq
    declared.each do |connector|
      assert Filing::Base.registered?(connector),
             "catalogue declares connector #{connector.inspect} but no class answers to it — " \
             "either build one or drop the header"
    end
  end
end
