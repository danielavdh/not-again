# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Hmrc
  # Makes authenticated calls to the HMRC MTD API.
  # Always call via .for_group — it refreshes the permission first.
  class Client
    ACCEPT_V1 = "application/vnd.hmrc.1.0+json".freeze
    ACCEPT_V2 = "application/vnd.hmrc.2.0+json".freeze
    ACCEPT_V3 = "application/vnd.hmrc.3.0+json".freeze
    ACCEPT_V5 = "application/vnd.hmrc.5.0+json".freeze
    ACCEPT_V6 = "application/vnd.hmrc.6.0+json".freeze

    # HMRC's typeOfBusiness → our scheme slug, so HMRC's vocabulary is
    # translated here, at the edge, once.
    #
    # Business Details v2 labels a UK property business "uk-property"; the pre-
    # April-2025 label was "uk-property-non-fhl". The sandbox still serves the
    # old one, real HMRC the new — accept both.
    SCHEME_FOR_BUSINESS_TYPE = {
      "self-employment"     => "gb_self_employment",
      "uk-property"         => "gb_property",
      "uk-property-non-fhl" => "gb_property"
    }.freeze

    # Built from a TAX REPORT GROUP, because that is where every part of a
    # submission comes from: the accounts, the taxpayer and the business id.
    # Anything smaller would let the token, the number and the business arrive
    # from different places.
    def self.for_group(group)
      Oauth.ensure_fresh!(group.taxpayer)
      new(taxpayer: group.taxpayer, group: group)
    end

    # For calls that need only the taxpayer — listing the businesses HMRC holds
    # for them, which is how you find out what a business id even is. There is
    # no group at that point: choosing one IS the thing being set up.
    def self.for_taxpayer(taxpayer)
      Oauth.ensure_fresh!(taxpayer)
      new(taxpayer: taxpayer)
    end

    def initialize(taxpayer:, group: nil)
      @taxpayer     = taxpayer
      @group        = group
      @access_token = taxpayer&.access_token
    end

    # Every business HMRC holds for this taxpayer, each with a businessId and a
    # typeOfBusiness.
    #
    # In the sandbox the "list businesses" call defaults to self-employment
    # only; a Gov-Test-Scenario header is needed to get a property business
    # back. Real HMRC ignores the header and returns the taxpayer's actual
    # businesses.
    def businesses
      headers = Config::SANDBOX ? { "Gov-Test-Scenario" => "BUSINESS_AND_PROPERTY" } : {}
      data    = get("/individuals/business/details/#{nino}/list", version: ACCEPT_V2, headers: headers)
      data.dig("listOfBusinesses") || data.dig("businesses") || []
    end

    # The businesses HMRC holds for this taxpayer that belong to a given scheme.
    # Returned rather than stored: which one these accounts ARE is a choice, and
    # it may be several — SA103F is about ONE named trade with its own address
    # and accounting period, so a taxpayer with two trades has two, while SA105
    # aggregates every let building into one UK property business.
    def businesses_for(scheme)
      slug = our_slug(scheme)
      businesses.select { |b| SCHEME_FOR_BUSINESS_TYPE[b["typeOfBusiness"]] == slug }
    end

    # ONE business in full, rather than the summary line #businesses returns.
    # HMRC's approvals checklist asks that software both LISTS and RETRIEVES
    # business details, and this is the only call carrying the accounting type,
    # the commencement date and the quarterly period type. Business Details v2
    # also gained tradingType in August 2026.
    #
    # Shape-defensive like #businesses: HMRC has wrapped this payload both ways
    # across versions, so accept the object bare or nested.
    def business_details(business_id)
      data = get("/individuals/business/details/#{nino}/#{business_id}", version: ACCEPT_V2)
      data["businessDetails"] || data
    end

    # Returns quarterly obligations from the Obligations (MTD) API.
    # scheme: :gb_self_employment or :gb_property
    def obligations(scheme:)
      business_id = business_id!
      # The Obligations v3 query expects "uk-property" for a property business;
      # the old FHL-era "uk-property-non-fhl" is rejected
      # (FORMAT_TYPE_OF_BUSINESS).
      type        = self_employment?(scheme) ? "self-employment" : "uk-property"
      from, to    = tax_year_range

      query = URI.encode_www_form(
        typeOfBusiness: type,
        businessId:     business_id,
        fromDate:       from,
        toDate:         to
      )
      # The sandbox test user's real obligations are frozen in the 2017-18 tax
      # year, which the current-model submission endpoints reject as out of
      # range. Gov-Test-Scenario DYNAMIC makes HMRC echo the requested date
      # range, so the flow is testable end to end. Real HMRC ignores the header.
      headers = Config::SANDBOX ? { "Gov-Test-Scenario" => "DYNAMIC" } : {}
      data = get("/obligations/details/#{nino}/income-and-expenditure?#{query}", version: ACCEPT_V3, headers: headers)
      parse_obligations(data)
    end

    # Submits a quarterly update for a specific period.
    # payload: Hash — see Hmrc::PayloadBuilder
    def submit_quarterly_update(scheme:, period_id:, payload:)
      business_id = business_id!
      start_date  = Date.parse(period_id.split("_").first)
      tax_year    = hmrc_tax_year(start_date)

      if cumulative_model?(start_date)
        # 2025-26 onwards: single PUT endpoint, create or amend
        if self_employment?(scheme)
          put("/individuals/business/self-employment/#{nino}/#{business_id}/cumulative/#{tax_year}", payload, version: ACCEPT_V5)
        else
          put("/individuals/business/property/uk/#{nino}/#{business_id}/cumulative/#{tax_year}", payload, version: ACCEPT_V6)
        end
      else
        # 2024-25 and earlier: POST to create, PUT to amend
        if self_employment?(scheme)
          # Self-employment period endpoint takes no tax year in the path; the
          # UK property one does — HMRC's two APIs differ here.
          post("/individuals/business/self-employment/#{nino}/#{business_id}/period", payload, version: ACCEPT_V5)
        else
          post("/individuals/business/property/uk/#{nino}/#{business_id}/period/#{tax_year}", payload, version: ACCEPT_V6)
        end
      end
    end

    # What HMRC currently holds for this business in the period's tax year — the
    # GET counterpart of the PUT in #submit_quarterly_update, on exactly the
    # same path. Required by the approvals checklist, and the only way to answer
    # "what did HMRC actually receive?" without leaving the app.
    #
    # nil before 2025-26: there is no cumulative summary in the per-period era,
    # where those are retrieved individually by their own period id.
    def cumulative_summary(scheme:, period_id:)
      start_date = Date.parse(period_id.split("_").first)
      return nil unless cumulative_model?(start_date)

      business_id = business_id!
      tax_year    = hmrc_tax_year(start_date)

      if self_employment?(scheme)
        get("/individuals/business/self-employment/#{nino}/#{business_id}/cumulative/#{tax_year}", version: ACCEPT_V5)
      else
        get("/individuals/business/property/uk/#{nino}/#{business_id}/cumulative/#{tax_year}", version: ACCEPT_V6)
      end
    end

    # HMRC's "Create and Amend Quarterly Period Type for a Business" — the only
    # way to elect calendar quarters instead of standard, since nothing in
    # HMRC's own online services can do it. Must be called before the tax year's
    # first quarterly update, and locks for that tax year once one has been
    # submitted: HMRC enforces that, so a call made too late is refused by them.
    #
    # tax_year: HMRC's own format, "2026-27". type: "standard" or "calendar",
    # verified against HMRC's published schema. 204 on success, the same empty-
    # body shape #submit_quarterly_update handles.
    def set_quarterly_period_type(business_id:, tax_year:, type:)
      put("/individuals/business/details/#{nino}/#{business_id}/#{tax_year}",
          { quarterlyPeriodType: type }, version: ACCEPT_V2)
    end

    private

    # Every path in this API is keyed on the NINO, so it is read once, here.
    # Normalised on the way out as well as in — HMRC will not match a stray
    # space.
    def nino
      @taxpayer&.identifier(:nino).to_s.gsub(/\s+/, "").upcase
    end

    # `scheme` arrives in HMRC's vocabulary from some callers ("property") and
    # in ours from others ("gb_property"). The only distinction the API makes is
    # self-employment or not, so collapse it to our slug.
    def our_slug(scheme)
      self_employment?(scheme) ? "gb_self_employment" : "gb_property"
    end

    # Which of this taxpayer's businesses these accounts are. On the GROUP,
    # because HMRC issues one per trade and one taxpayer may have several.
    def business_id!
      raise "No tax report group — this call needs one." if @group.nil?
      id = @group.business_id
      raise "No HMRC business ID on tax report group #{@group.id} (#{@group.display_name}). " \
            "Connect and choose the business first." if id.blank?
      id
    end

    def self_employment?(scheme)
      scheme.to_s == "gb_self_employment"
    end

    def parse_obligations(data)
      (data["obligations"] || []).flat_map do |ob|
        (ob["obligationDetails"] || []).map do |d|
          # HMRC says "F" or "O"; the app says :fulfilled or :open. Translated
          # HERE, at the edge, exactly as typeOfBusiness is, so no shared view
          # or controller ever learns one authority's alphabet.
          status   = d["status"].to_s.downcase.start_with?("f") ?
                       Filing::Base::STATUS_FULFILLED : Filing::Base::STATUS_OPEN
          due_date = Date.parse(d["dueDate"])
          {
            period_id:  "#{d['periodStartDate']}_#{d['periodEndDate']}",
            start_date: Date.parse(d["periodStartDate"]),
            end_date:   Date.parse(d["periodEndDate"]),
            due_date:   due_date,
            # Past its due date. A fact about the obligation, decided here
            # rather than by each template that wants to colour a button.
            overdue:    due_date < Date.current,
            status:     status
          }
        end
      end
    end

    def tax_year_range
      today = Date.today
      if today >= Date.new(today.year, 4, 6)
        [ Date.new(today.year, 4, 6).to_s, Date.new(today.year + 1, 4, 5).to_s ]
      else
        [ Date.new(today.year - 1, 4, 6).to_s, Date.new(today.year, 4, 5).to_s ]
      end
    end

    def hmrc_tax_year(date)
      Hmrc::TaxYear.label(date)
    end

    def cumulative_model?(date)
      Hmrc::TaxYear.cumulative?(date)
    end

    def get(path, version: ACCEPT_V1, headers: {})
      request_json(Net::HTTP::Get, path, nil, version, headers)
    end

    def post(path, body, version: ACCEPT_V1)
      request_json(Net::HTTP::Post, path, body, version)
    end

    def put(path, body, version: ACCEPT_V1)
      request_json(Net::HTTP::Put, path, body, version)
    end

    def request_json(method_class, path, body = nil, accept = ACCEPT_V1, extra_headers = {})
      uri  = URI("#{Config::API_BASE}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = 10
      http.read_timeout = 30

      # request_uri keeps the query string; uri.path would drop it, so GET
      # params (e.g. the obligations filters) would never reach HMRC.
      request = method_class.new(uri.request_uri)
      request["Authorization"] = "Bearer #{@access_token}"
      request["Accept"]        = accept
      fraud_prevention_headers.each { |k, v| request[k] = v }
      extra_headers.each { |k, v| request[k] = v }
      if body
        request["Content-Type"] = "application/json"
        request.body = body.to_json
      end

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        parsed  = parse_body(response.body)
        code    = parsed["code"]    || response.code
        message = parsed["message"] || parsed["errors"]&.map { |e| e["message"] }&.join("; ") || response.message
        Rails.logger.error "HMRC API #{response.code} for #{path}: #{response.body.to_s.truncate(500)}"
        raise "HMRC API error #{code}: #{message}"
      end

      parse_body(response.body)
    end

    # HMRC's mandatory fraud prevention headers, built per-request by the
    # controller and stashed on Current. Empty in non-request contexts; every
    # real HMRC API call runs in-request. Kept in the HMRC client so no other
    # authority's client can send them.
    def fraud_prevention_headers
      Current.fraud_prevention_headers || {}
    end

    # HMRC returns 204 No Content on a successful cumulative submission, while
    # most other calls return a JSON body. An empty or blank body is a valid
    # empty result — parsing it would raise (TypeError on nil, ParserError on
    # "") and turn a success into a failure.
    def parse_body(body)
      return {} if body.nil? || body.to_s.strip.empty?
      JSON.parse(body)
    end
  end
end
