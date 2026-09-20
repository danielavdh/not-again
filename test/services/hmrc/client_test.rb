# frozen_string_literal: true
require "test_helper"

class Hmrc::ClientTest < ActiveSupport::TestCase
  setup do
    @entity       = entities(:family_biz)
    @taxpayer = admins(:sudo).taxpayers.create!(authority: "hmrc")
    @taxpayer.set_identifier(:nino, "AB123456C")
    @taxpayer.save!
    @group  = @entity.report_groups.create!(name: "se", tax_scheme: "gb_self_employment",
                                            taxpayer: @taxpayer)
    @client = Hmrc::Client.new(taxpayer: @taxpayer, group: @group)
  end

  def store_business_id(_scheme, id)
    @group.update!(business_id: id)
  end

  # The client LISTS what HMRC holds and stores nothing. Which business these
  # accounts are is a choice, and for self-employment there may be several —
  # SA103F is about one named trade with its own accounting period.
  test "businesses_for returns every business of that scheme, not one" do
    list = { "listOfBusinesses" => [
      { "typeOfBusiness" => "self-employment", "businessId" => "SE111" },
      { "typeOfBusiness" => "self-employment", "businessId" => "SE222" },
      { "typeOfBusiness" => "uk-property",     "businessId" => "PR333" }
    ] }
    found = @client.stub(:get, list) { @client.businesses_for("gb_self_employment") }
    assert_equal %w[SE111 SE222], found.map { |b| b["businessId"] }
  end

  test "the legacy uk-property-non-fhl label still counts as property" do
    list = { "listOfBusinesses" => [
      { "typeOfBusiness" => "uk-property-non-fhl", "businessId" => "PR999" }
    ] }
    found = @client.stub(:get, list) { @client.businesses_for("gb_property") }
    assert_equal %w[PR999], found.map { |b| b["businessId"] }
  end

  test "a missing business id names the group, not the entity" do
    @group.update!(business_id: nil)
    e = assert_raises(RuntimeError) { @client.obligations(scheme: "gb_self_employment") }
    assert_match(/tax report group/, e.message)
  end

  # ---- retrieval endpoints (HMRC's approvals checklist: list AND retrieve)
  # ----

  def captured_get(&block)
    captured = {}
    @client.define_singleton_method(:get) { |path, **kw| captured.merge!(path: path, version: kw[:version]); {} }
    block.call
    captured
  end

  test "business_details retrieves ONE business, not the list" do
    store_business_id("gb_self_employment", "SE1")
    c = captured_get { @client.business_details("SE1") }
    assert_equal "/individuals/business/details/AB123456C/SE1", c[:path]
    assert_equal Hmrc::Client::ACCEPT_V2, c[:version]
  end

  test "business_details accepts the payload bare or nested" do
    nested = { "businessDetails" => { "businessId" => "SE1" } }
    bare   = { "businessId" => "SE1" }
    assert_equal({ "businessId" => "SE1" }, @client.stub(:get, nested) { @client.business_details("SE1") })
    assert_equal({ "businessId" => "SE1" }, @client.stub(:get, bare)   { @client.business_details("SE1") })
  end

  # The GET mirrors the PUT exactly — same path, same version. A divergence here
  # is the trap that bit the property submission twice, missing /uk/ and missing
  # the tax year, so it is pinned for both schemes.
  test "cumulative_summary GETs the same path the submission PUTs (self-employment)" do
    store_business_id("gb_self_employment", "SE1")
    c = captured_get { @client.cumulative_summary(scheme: "gb_self_employment", period_id: "2026-07-06_2026-10-05") }
    assert_equal "/individuals/business/self-employment/AB123456C/SE1/cumulative/2026-27", c[:path]
    assert_equal Hmrc::Client::ACCEPT_V5, c[:version]
  end

  test "cumulative_summary GETs the same path the submission PUTs (uk property)" do
    store_business_id("gb_property", "PR1")
    c = captured_get { @client.cumulative_summary(scheme: "property", period_id: "2026-07-06_2026-10-05") }
    assert_equal "/individuals/business/property/uk/AB123456C/PR1/cumulative/2026-27", c[:path]
    assert_equal Hmrc::Client::ACCEPT_V6, c[:version]
  end

  # There is no cumulative summary before 2025-26 — those periods are retrieved
  # individually by their own id. Returning nil beats calling an endpoint that
  # does not exist for that era.
  test "cumulative_summary is nil in the pre-2025-26 per-period era" do
    store_business_id("gb_self_employment", "SE1")
    assert_nil @client.cumulative_summary(scheme: "gb_self_employment", period_id: "2018-07-06_2018-10-05")
  end

  # ---- submission endpoint paths (HMRC's SE and property APIs differ) ----

  def submission_path(scheme:, period_id:)
    captured = {}
    @client.define_singleton_method(:put)  { |path, _body, **| captured.merge!(method: :put,  path: path) }
    @client.define_singleton_method(:post) { |path, _body, **| captured.merge!(method: :post, path: path) }
    @client.submit_quarterly_update(scheme: scheme, period_id: period_id, payload: {})
    captured
  end

  test "self-employment cumulative (2025-26+) PUTs to the cumulative endpoint" do
    store_business_id("gb_self_employment", "SE1")
    c = submission_path(scheme: "gb_self_employment", period_id: "2026-07-06_2026-10-05")
    assert_equal :put, c[:method]
    assert_equal "/individuals/business/self-employment/AB123456C/SE1/cumulative/2026-27", c[:path]
  end

  test "uk property cumulative (2025-26+) PUTs to /property/uk/.../cumulative" do
    store_business_id("gb_property", "PR1")
    c = submission_path(scheme: "property", period_id: "2026-07-06_2026-10-05")
    assert_equal :put, c[:method]
    assert_equal "/individuals/business/property/uk/AB123456C/PR1/cumulative/2026-27", c[:path]
  end

  test "self-employment period (<=2024-25) POSTs to /period with no tax year" do
    store_business_id("gb_self_employment", "SE1")
    c = submission_path(scheme: "gb_self_employment", period_id: "2018-07-06_2018-10-05")
    assert_equal :post, c[:method]
    assert_equal "/individuals/business/self-employment/AB123456C/SE1/period", c[:path]
  end

  test "uk property period (<=2024-25) POSTs to /period/{taxYear}" do
    store_business_id("gb_property", "PR1")
    c = submission_path(scheme: "property", period_id: "2018-07-06_2018-10-05")
    assert_equal :post, c[:method]
    assert_equal "/individuals/business/property/uk/AB123456C/PR1/period/2018-19", c[:path]
  end

  # ---- quarterly period type election ----

  def captured_put(&block)
    captured = {}
    @client.define_singleton_method(:put) { |path, body, **kw| captured.merge!(path: path, body: body, version: kw[:version]); {} }
    block.call
    captured
  end

  test "set_quarterly_period_type PUTs to the business details endpoint for that tax year" do
    c = captured_put { @client.set_quarterly_period_type(business_id: "SE1", tax_year: "2026-27", type: "calendar") }
    assert_equal "/individuals/business/details/AB123456C/SE1/2026-27", c[:path]
    assert_equal({ quarterlyPeriodType: "calendar" }, c[:body])
    assert_equal Hmrc::Client::ACCEPT_V2, c[:version]
  end

  test "set_quarterly_period_type sends whichever type it is given, standard or calendar" do
    c = captured_put { @client.set_quarterly_period_type(business_id: "SE1", tax_year: "2026-27", type: "standard") }
    assert_equal({ quarterlyPeriodType: "standard" }, c[:body])
  end

  # ---- response parsing (a successful cumulative submit is 204 No Content)
  # ----

  class FakeHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout
    attr_reader :last_path

    def initialize(response)
      @response = response
    end

    def request(req)
      @last_path = req.path
      @response
    end
  end

  test "GET requests keep their query string (uri.path would drop it)" do
    resp = Net::HTTPOK.new("1.1", "200", "OK")
    def resp.body; "{}"; end
    fake = FakeHTTP.new(resp)

    Net::HTTP.stub(:new, ->(*_) { fake }) do
      @client.send(:request_json, Net::HTTP::Get, "/foo?bar=baz")
    end
    assert_equal "/foo?bar=baz", fake.last_path
  end

  test "obligations query uses the uk-property type and the businessId filter" do
    store_business_id("gb_property", "PR1")
    captured = nil
    @client.define_singleton_method(:get) { |path, **_| captured = path; { "obligations" => [] } }

    @client.obligations(scheme: "gb_property")
    assert_includes captured, "typeOfBusiness=uk-property"
    assert_includes captured, "businessId=PR1"
  end

  test "parse_body treats nil and blank bodies as an empty result" do
    assert_equal({}, @client.send(:parse_body, nil))
    assert_equal({}, @client.send(:parse_body, ""))
    assert_equal({}, @client.send(:parse_body, "   "))
    assert_equal({ "a" => 1 }, @client.send(:parse_body, '{"a":1}'))
  end

  test "a 204 No Content success returns {} instead of raising" do
    resp = Net::HTTPNoContent.new("1.1", "204", "No Content")
    def resp.body; nil; end

    Net::HTTP.stub(:new, ->(*_) { FakeHTTP.new(resp) }) do
      assert_equal({}, @client.send(:request_json, Net::HTTP::Put, "/x", { a: 1 }))
    end
  end
end
