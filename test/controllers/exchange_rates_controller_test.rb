# frozen_string_literal: true
require "test_helper"

class ExchangeRatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = admins(:one)
    sign_in_as(@admin)

    # Create an exchange rate for testing since we don't have fixtures
    @exchange_rate = ExchangeRate.create!(
      from_currency: "GBP",
      to_currency: "EUR",
      rate: 1.15,
      effective_date: Date.current
    )
  end

  test "should get index" do
    get exchange_rates_url(locale: :en)
    assert_response :success
  end

  # audit I5: an entity's own rate and its private evidence note are only for
  # an admin linked to that entity.
  test "an entity's own rate is hidden from an admin with no link to it" do
    foreign = entities(:family_biz) # admins(:one) has no link (holds 01, 03)
    assert_not @admin.accessible_entity_ids.include?(foreign.id)
    owned = ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", rate: 0.8,
      effective_date: Date.current, valid_from: Date.current.beginning_of_month,
      valid_to: Date.current.end_of_month, entity_id: foreign.id,
      note: "Konzernumrechnungskurs, Bank Vontobel ref 88123")

    get exchange_rates_url(locale: :en)
    assert_no_match "Vontobel", response.body
    assert_no_match "88123", response.body

    get edit_exchange_rate_url(locale: :en, id: owned)
    assert_redirected_to exchange_rates_path(locale: :en)

    get exchange_rate_url(locale: :en, id: owned)
    assert_redirected_to exchange_rates_path(locale: :en)

    get exchange_rates_url(locale: :en, format: :csv)
    assert_no_match "USD", response.body, "the hidden rate must not leak into the CSV either"
  end

  test "should get new" do
    get new_exchange_rate_url(locale: :en)
    assert_response :success
  end

  def rate_params(extra = {})
    { from_currency: "GBP", to_currency: "USD", rate: 1.25,
      valid_from: Date.current.beginning_of_month,
      valid_to: Date.current.end_of_month }.merge(extra)
  end

  # The form asks for a validity SPAN rather than a single date: a month-end
  # spot rate and a monthly average are indistinguishable when both are stored
  # as one date.
  #
  # Leaving the entity blank means "all of my entities", writing one row each —
  # a typed rate is NEVER global, so one submission becomes as many rows as the
  # admin has businesses.
  test "creating without an entity writes one rate per entity the admin owns" do
    expected = @admin.writable_entity_codes.size
    assert_operator expected, :>, 0, "this test needs the admin to own something"

    assert_difference("ExchangeRate.count", expected) do
      post exchange_rates_url(locale: :en), params: { exchange_rate: rate_params }
    end
    assert_redirected_to exchange_rates_url(locale: :en)

    written = ExchangeRate.where(entered_by: @admin)
    assert written.all? { |r| r.entity_id.present? }, "a typed rate is never global"
    assert written.all? { |r| r.source == "manual" },     "a typed rate is nobody's publication"
  end

  test "creating for one entity writes exactly one" do
    entity = Entity.find_by(code: @admin.writable_entity_codes.first)

    assert_difference("ExchangeRate.count", 1) do
      post exchange_rates_url(locale: :en),
           params: { exchange_rate: rate_params(entity_id: entity.id) }
    end
  end

  # Nothing else can check a typed rate — no publisher covers most pairs — and
  # both ways of getting it wrong read as ordinary numbers. Saying it back is
  # the only place the magnitude and the direction are ever stated.
  #
  # Asserted on rate_sentence rather than on the flash wording: the keys carry
  # %{rate} only once Daniela adds it (docs/gitignored/translations.md), so
  # this passes before and after that lands.
  test "saving a rate says back which way round and how big it is" do
    entity = Entity.find_by(code: @admin.writable_entity_codes.first)

    post exchange_rates_url(locale: :en),
         params: { exchange_rate: rate_params(entity_id: entity.id, from_currency: "GBP",
                                              to_currency: "USD", rate: "1.25") }

    assert_equal "1 GBP = 1.25 USD", ExchangeRate.order(:created_at).last.rate_sentence
  end

  test "the echoed sentence names the currencies the way the rate is stored, not the reverse" do
    rate = ExchangeRate.new(from_currency: "EUR", to_currency: "GBP", rate: "0.85")

    assert_equal "1 EUR = 0.85 GBP", rate.rate_sentence
    assert_not_equal "1 GBP = 0.85 EUR", rate.rate_sentence
  end

  # The case the echo exists for: "17.000" typed by a German admin casts to 17
  # and passes every validation, so the only thing that can catch it is reading
  # the magnitude back.
  test "a rate that silently lost three digits still reads back as what was stored" do
    rate = ExchangeRate.new(from_currency: "EUR", to_currency: "IDR", rate: "17.000")

    assert_equal 17, rate.rate.to_i, "precondition: '17.000' casts to seventeen"
    assert_equal "1 EUR = 17 IDR", rate.rate_sentence
  end

  # Refusing used to be silent: `refuse` set flash.now and rendered a template
  # that did not include the flash partial, so the browser got a bare 403 and
  # the page said nothing.
  test "a refused write says why, rather than failing silently" do
    other = Entity.create!(code: "97", name: "Not theirs", active: true)

    assert_no_difference("ExchangeRate.count") do
      post exchange_rates_url(locale: :en),
           params: { exchange_rate: rate_params(entity_id: other.id) }
    end
    assert_response :forbidden
    assert_match(/entity/i, response.body, "the page must explain the refusal")
  end

  test "should show exchange rate" do
    get exchange_rate_url(locale: :en, id: @exchange_rate)
    assert_response :success
  end

  test "should get edit" do
    get edit_exchange_rate_url(locale: :en, id: @exchange_rate)
    assert_response :success
  end

  # The fixture rate has no entity, so it is part of the SHARED series — sudo's
  # to change, nobody else's.
  test "sudo may update a shared rate" do
    sign_in_as(admins(:sudo))
    patch exchange_rate_url(locale: :en, id: @exchange_rate), params: {
      exchange_rate: { rate: 1.20 }
    }
    assert_redirected_to exchange_rates_url(locale: :en)
  end

  test "an ordinary admin may not" do
    patch exchange_rate_url(locale: :en, id: @exchange_rate), params: {
      exchange_rate: { rate: 1.20 }
    }
    assert_response :forbidden
    assert_in_delta 1.15, @exchange_rate.reload.rate.to_f, 0.0001, "the rate must be untouched"
  end

  # Editing must not stamp source: "manual", or sudo correcting a fetched ECB
  # figure turns it into a GLOBAL MANUAL row — the one combination ruled out. It
  # matters most for ESTV, whose past months can never be re-fetched: "delete
  # and pull it again" is not available there, so correcting in place has to
  # stay possible without changing what the row IS.
  test "editing a shared rate leaves it shared, and leaves its source alone" do
    sign_in_as(admins(:sudo))
    patch exchange_rate_url(locale: :en, id: @exchange_rate), params: {
      exchange_rate: { rate: 1.42 }
    }

    @exchange_rate.reload
    assert_in_delta 1.42, @exchange_rate.rate.to_f, 0.0001
    assert_nil @exchange_rate.entity_id, "it must stay part of the shared series"
    assert_equal "manual", @exchange_rate.source, "the fixture's own source, unchanged"
    assert_equal admins(:sudo).id, @exchange_rate.entered_by_id, "who touched it is recorded"
  end

  # A rate's publisher is not a user's to assert. The form has no source field,
  # so this can only arrive from a crafted request.
  test "a submitted source is ignored" do
    sign_in_as(admins(:sudo))
    entity = Entity.find_by(code: admins(:one).writable_entity_codes.first)

    post exchange_rates_url(locale: :en), params: {
      exchange_rate: rate_params(entity_id: entity.id, source: "ecb")
    }

    written = ExchangeRate.where(entity_id: entity.id).last
    assert_equal "manual", written.source,
                 "a typed figure must never be filed as a publisher's"
  end

  test "sudo may destroy a shared rate" do
    sign_in_as(admins(:sudo))
    assert_difference("ExchangeRate.count", -1) do
      delete exchange_rate_url(locale: :en, id: @exchange_rate)
    end
    assert_redirected_to exchange_rates_url(locale: :en)
  end

  test "an ordinary admin may not destroy one" do
    assert_no_difference("ExchangeRate.count") do
      delete exchange_rate_url(locale: :en, id: @exchange_rate)
    end
  end

  test "lookup returns rate for valid currencies" do
    get lookup_exchange_rates_url(locale: :en),
        params: { from: "GBP", to: "EUR", date: Date.current.to_s }
    assert_response :success
    body = response.parsed_body
    assert body.key?("rate")
    assert body.key?("source")
  end

  test "lookup rejects invalid currency codes" do
    get lookup_exchange_rates_url(locale: :en),
        params: { from: "FAKE", to: "EUR", date: Date.current.to_s }
    assert_response :unprocessable_entity
    body = response.parsed_body
    assert_equal "Invalid currency", body["error"]
  end

  # TWO FLASHES THAT COULD NOT BOTH BE TRUE:
  #
  # ask ESTV for July   → "does not serve past months … 4 rates stored for
  # 2026-08"
  # ask ESTV for August → "ESTV rates for 2026-08 are not yet available"
  #
  # while August's four rates sat in the table. ESTV serves a ROLLING CURRENT
  # MONTH, its window running the 25th to the 24th, so it has this month now.
  # Waiting for month end is only right for a source that computes after the
  # fact AND can be asked for an earlier period.
  test "a source that only serves the current month may be asked for it" do
    sign_in_as(admins(:sudo))
    result = { success: true, count: 4,
               valid_from: Date.current.beginning_of_month,
               valid_to: Date.current.end_of_month }

    Rates::Fetcher.stub(:fetch_and_store, result) do
      post fetch_rates_exchange_rates_path(locale: :en),
           params: { source: "estv", month: Date.current.strftime("%Y-%m") }
    end

    assert_no_match(/not yet available/i, flash[:alert].to_s,
                    "ESTV has the current month by definition")
  end

  # But a source that computes AFTER the month must still wait for it to end,
  # which is what the rule was there for in the first place.
  test "an average computed after the fact still waits for month end" do
    sign_in_as(admins(:sudo))

    post fetch_rates_exchange_rates_path(locale: :en),
         params: { source: "bundesbank", month: Date.current.strftime("%Y-%m") }

    assert_match(/not yet available/i, flash[:alert].to_s)
  end

  test "and nobody is asked for a month that has not begun" do
    sign_in_as(admins(:sudo))

    post fetch_rates_exchange_rates_path(locale: :en),
         params: { source: "estv", month: Date.current.next_month.strftime("%Y-%m") }

    assert_match(/not yet available/i, flash[:alert].to_s)
  end
end
