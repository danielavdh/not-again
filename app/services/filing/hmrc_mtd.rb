# frozen_string_literal: true

module Filing
  class HmrcMtd < Base
    # ## Legal implications of this connector
    #
    # Data that would otherwise stay in the books gets sent to an outside
    # authority.
    # The /legal page needs to inform the user of this fact.
    # The correct text for THIS connector needs to be added under 
    # `filing.hmrc.legal_html` in each locale file. 
    # English (verified against what this connector actually sends —
    # `Hmrc::PayloadBuilder`, `Hmrc::FraudPreventionHeaders`, `Hmrc::Oauth`):
    ################## LEGAL TEXT FOR HMRC ##################################
    #   When you file through HMRC's Making Tax Digital service, the relevant
    #   income and expense figures — together with the fraud-prevention data
    #   HMRC requires with every submission — are transmitted to HM Revenue
    #   & Customs on your instruction. HMRC is a separate data controller for
    #   what it receives. The OAuth authorisation tokens that let us file on
    #   your behalf are stored encrypted, and used only for that purpose.
    #########################################################################
    #
    # HMRC identifies the taxpayer by National Insurance number, and it is in
    # the path of every call — so nothing can be done for someone until it is
    # known. The business identifiers are NOT here: those belong to a trade,
    # and live on the tax report group that is that trade.
    IDENTIFIERS   = %w[nino].freeze
    AUTHORITY_KEY = "hmrc"

    # The fields of HMRC's Retrieve Business Details response worth showing, in
    # reading order. tradingType arrived with the August 2026 release of
    # Business Details v2; older records have none and it drops out.
    BUSINESS_DETAIL_FIELDS = %w[
      tradingName tradingType typeOfBusiness accountingType
      commencementDate cessationDate
    ].freeze

    # HMRC's Production Approvals Checklist requires software covering only part
    # of the obligation to say so on screen, and to link their list of
    # compatible software. Their URLs, so they sit with the connector rather
    # than in a template or a locale file.
    COMPATIBLE_SOFTWARE_URL  = "https://www.gov.uk/guidance/find-software-thats-compatible-with-making-tax-digital-for-income-tax"
    PERSONAL_TAX_ACCOUNT_URL = "https://www.gov.uk/personal-tax-account"

    # HMRC's mandatory fraud prevention headers, built from the request that
    # triggered the call and stashed on Current, where Hmrc::Client picks them
    # up. Browser-collected values arrive in the gov_client_data cookie, set by
    # HmrcFraudPrevention in tax.js.
    #
    # HMRC's alone: no other authority asks for anything like it, so it belongs
    # on the connector rather than in a controller that serves them all.
    def self.prepare_request(request:, admin:, cookies:, session:)
      Current.fraud_prevention_headers = Hmrc::FraudPreventionHeaders.new(
        request: request,
        admin:   admin,
        browser: browser_data(cookies),
        mfa_at:  session[:otp_verified].is_a?(Hash) ? session[:otp_verified]["at"] : nil
      ).to_h
    end

    # What is REGISTERED at HMRC's developer hub, character for character. A
    # redirect URI that differs by one character is refused, so this is a fact
    # about HMRC's account rather than about the app.
    #
    # Registered and verified by connecting in development and in production:
    # http://localhost:3000/entities/filing_callback
    # https://books.example.eu/entities/filing_callback
    #
    # It equals Base's neutral default, so this override exists only to record
    # the above — which is worth recording, because a successful connect is the
    # ONLY proof that what we send matches what is registered.
    #
    # Keep this list current. If someone changes the app's host, or adds an
    # environment, the new URI has to be added at HMRC's developer hub BEFORE it
    # is sent from here, and the hub allows five in total.
    REGISTERED_CALLBACK_PATH = "/entities/filing_callback"

    def self.registered_callback_path
      REGISTERED_CALLBACK_PATH
    end

    # The browser half of the fraud prevention headers — see HmrcFraudPrevention
    # in scripts/tax.js, which writes the gov_client_data cookie that
    # .prepare_request reads back.
    def self.browser_collector
      "hmrc_fraud_prevention"
    end

    # A malformed cookie is not an error worth failing a submission over — the
    # headers degrade to what the server can see for itself.
    def self.browser_data(cookies)
      raw = cookies[:gov_client_data]
      raw.present? ? JSON.parse(raw) : {}
    rescue JSON::ParserError
      {}
    end
    private_class_method :browser_data

    # HMRC will not match a NINO with spaces in it, and rejects lower case.
    def self.normalise_identifier(key, value)
      return super unless key.to_s == "nino"
      value.to_s.gsub(/\s+/, "").upcase.presence
    end

    # Two letters, six digits, a final letter A–D. Checked here rather than at
    # submission because a typo caught while setting the client up costs a
    # correction, and one caught by HMRC costs a rejected return.
    #
    # The loose form on purpose: HMRC also bars certain prefixes, but those
    # rules have changed before, and a validation that rejects a real NINO is
    # worse than one that lets a fake through — the authority checks it either
    # way.
    NINO_FORMAT = /\A[A-Z]{2}\d{6}[A-D]\z/
    def self.valid_identifier?(key, value)
      return super unless key.to_s == "nino"
      NINO_FORMAT.match?(value.to_s)
    end

    # tradingName is optional in HMRC's own schema — only businessId and
    # typeOfBusiness are required — and SA103F box 1 says why: "Business name —
    # unless it's in your own name". So a sole trader trading as themselves has
    # none to give, and two of them are indistinguishable.
    def self.business_name(business)
      business["tradingName"]
    end

    # HMRC's guidance page rather than the service itself: it survives service
    # moves, and covers the post and telephone routes for anyone whose Gateway
    # login does not get them there.
    def self.business_name_help_url
      "https://www.gov.uk/tell-hmrc-changed-business-details"
    end

    def connect_url(callback_uri:, state:)
      Hmrc::Oauth.authorization_url(redirect_uri: callback_uri, state: state)
    end

    def handle_callback(params:, redirect_uri:)
      result = Hmrc::Oauth.exchange_code(
        code:         params[:code],
        redirect_uri: redirect_uri
      )
      taxpayer.update!(
        access_token:     result[:access_token],
        refresh_token:    result[:refresh_token],
        token_expires_at: Time.current + result[:expires_in].seconds
      )
    end

    def disconnect
      taxpayer.clear!
    end

    # ONE call for every scheme at this authority — the list is per taxpayer,
    # not per business, so asking once and grouping is right. Types HMRC uses
    # that we have no scheme for (foreign-property today) drop out.
    def businesses_by_scheme
      Hmrc::Client.for_taxpayer(taxpayer).businesses
        .group_by { |b| Hmrc::Client::SCHEME_FOR_BUSINESS_TYPE[b["typeOfBusiness"]] }
        .except(nil)
    rescue => e
      Rails.logger.warn "HMRC business list failed for #{entity.code}: #{e.class}: #{e.message}"
      {}
    end

    # HMRC requires statements on screen that no other authority has an
    # equivalent of, and their Business Details record is worth showing beside
    # the obligations. Both live under app/views/filing/hmrc_mtd/.
    def panel_partial
      "filing/hmrc_mtd/panels"
    end

    def periods
      obs    = client.obligations(scheme: hmrc_scheme_name)
      sorted = obs.sort_by { |ob| ob[:start_date] }.reverse

      next_due = obs.select { |ob| ob[:status] == Base::STATUS_OPEN }.min_by { |ob| ob[:due_date] }
      preview  = if next_due
        start_d = cumulative_start(next_due[:start_date], next_due[:end_date], obs)
        {
          obligation:   next_due,
          period_start: start_d,
          currency:     submission_currency,
          breakdown:    build_breakdown(start_d, next_due[:end_date])
        }
      end

      # Worked out from the obligations already in hand — report_period on its
      # own would re-fetch them once per obligation.
      report_periods = obs.to_h { |ob|
        [ ob[:period_id], [ cumulative_start(ob[:start_date], ob[:end_date], obs), ob[:end_date] ] ]
      }

      { obligations: sorted, preview: preview, error: nil, report_periods: report_periods,
        business: business_details, filed: filed_summary(next_due) }
    rescue => e
      Rails.logger.warn "HMRC obligations fetch failed for #{scheme}: #{e.message}"
      { obligations: [], preview: nil, error: e.message, report_periods: {},
        business: nil, filed: nil }
    end

    def submit(period_id:, view_url:, &renderer)
      quarter_start, quarter_end = period_dates(period_id)
      # Cumulative model (2025-26+): a quarterly submission covers the whole tax
      # year to date, so it starts at the tax-year boundary, not the quarter
      # start. Payload, archived document and preview all use this range so they
      # match exactly what HMRC receives.
      start_d = cumulative_start(quarter_start, quarter_end)
      accounts = scheme_accounts(start_d, quarter_end)

      # OUR scheme slug, not hmrc_scheme_name. The builder filters accounts and
      # catalogue rows, both of which store "gb_property"; hmrc_scheme_name
      # returns "property", which matches nothing and produces an empty payload.
      # hmrc_scheme_name stays for the client, where HMRC's own naming applies.
      payload = Hmrc::PayloadBuilder.new(
        entity:           entity,
        accounts:         accounts,
        start_date:       start_d,
        end_date:         quarter_end,
        scheme:           scheme,
        display_currency: submission_currency
      ).build

      # HMRC's reference for this submission: the legacy self-employment
      # endpoint returns a periodId, legacy property a submissionId, and the
      # cumulative (2025-26+) endpoints return 204 with no body. Logged as an
      # audit trail of acceptance — the archive itself keys on quarter_end.
      result = client.submit_quarterly_update(
        scheme:    hmrc_scheme_name,
        period_id: period_id,
        payload:   payload
      )
      Rails.logger.info(
        "HMRC submission accepted for #{entity.code} #{scheme} #{period_id}: #{result.presence || '204 No Content'}"
      )

      render_and_enqueue_archive(start_d, quarter_end, accounts, view_url, &renderer)
    end

    # What a submission for this period actually covers. From 2025-26 that is
    # the tax year to date, not the quarter alone, so a report opened from a
    # filing shows the same figures HMRC received.
    def report_period(period_id)
      quarter_start, quarter_end = period_dates(period_id)
      [ cumulative_start(quarter_start, quarter_end), quarter_end ]
    end

    def view_html(period_id:)
      end_d    = period_dates(period_id).last
      filename = Filing::Storage.filename_for(entity: entity, scheme: scheme, period_end: end_d, group: "MTD")
      Filing::Storage.fetch_html(filename)
    end

    private

    # The taxpayer this filing is for. Never created here — a taxpayer belongs
    # to an admin and is chosen. Supplied directly when connecting; otherwise
    # read from the group being filed.
    def taxpayer
      chosen = super || group&.taxpayer
      return chosen if chosen
      raise "No taxpayer chosen for #{entity.code} #{scheme} — pick a taxpayer first."
    end

    # One scheme, one entity, one group. This is the object the whole
    # submission is built from.
    def group
      return @group if defined?(@group)
      @group = entity.report_groups.find_by(tax_scheme: scheme)
    end

    # HMRC's own record of the business we file for, so the trade the figures
    # land against is visible rather than assumed, and a wrong business id shows
    # up on screen instead of being filed against silently.
    #
    # Non-fatal on purpose: the obligations ARE the page. Losing this costs
    # context, and taking the page down with it would cost the filing.
    def business_details
      id = group&.business_id
      return [] if id.blank?
      normalise_business(client.business_details(id))
    rescue => e
      Rails.logger.warn "HMRC business details fetch failed for #{scheme}: #{e.message}"
      []
    end

    # HMRC's field names, and the order they read best in, are facts about their
    # API, so they live here and the view only loops. Blanks drop out:
    # cessationDate is absent for a trading business, tradingType only exists
    # from August 2026, and an empty row says nothing.
    def normalise_business(data)
      return [] if data.blank?

      pairs = BUSINESS_DETAIL_FIELDS.map { |f| [ f.underscore, data[f] ] }
      pairs << [ "quarterly_period_type", data.dig("quarterlyTypeChoice", "quarterlyPeriodType") ]

      pairs.reject { |_k, v| v.blank? }
           .map    { |k, v| [ k, display_value(v) ] }
    end

    # HMRC sends dates as ISO strings; everything else is shown exactly as they
    # hold it, because this panel IS their record and paraphrasing it would
    # defeat the point of showing it.
    def display_value(value)
      return value unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      I18n.l(Date.parse(value), format: :short_date)
    rescue Date::Error
      value
    end

    # submittedOn is an ISO8601 timestamp. Formatted here rather than in the
    # template, so the view stays a loop over ready-made strings.
    def display_timestamp(value)
      return nil if value.blank?
      t = Time.parse(value)
      "#{I18n.l(t, format: :short_date)}, #{t.strftime('%H:%M')}"
    rescue ArgumentError
      value
    end

    # What HMRC already holds for the open period's tax year, shown beside what
    # we are about to send. nil before 2025-26.
    #
    # A 404 here is NORMAL, not a failure: before the first submission of a tax
    # year there is nothing to retrieve. So this logs at info and returns nil,
    # and the page simply does not show the panel.
    def filed_summary(obligation)
      return nil unless obligation
      data = client.cumulative_summary(scheme: hmrc_scheme_name, period_id: obligation[:period_id])
      return nil if data.blank?
      { submitted_on: display_timestamp(data["submittedOn"]) }
    rescue => e
      Rails.logger.info "HMRC cumulative summary unavailable for #{scheme}: #{e.message}"
      nil
    end

    def client
      @client ||= Hmrc::Client.for_group(group)
    end

    def hmrc_scheme_name
      scheme == "gb_property" ? "property" : scheme
    end

    def period_dates(period_id)
      period_id.split("_").map { |d| Date.parse(d) }
    end

    # Start date of the submission for a given quarter. Pre-2025-26 stays per-
    # quarter. For the cumulative model it is the first day of the tax year,
    # read from HMRC's obligations — the earliest period start in the same tax
    # year — rather than hardcoded, so standard and calendar quarters both work.
    # Falls back to the computed 6 April boundary if obligations are
    # unavailable.
    def cumulative_start(quarter_start, quarter_end, obligations = nil)
      return quarter_start unless Hmrc::TaxYear.cumulative?(quarter_start)

      obligations ||= safe_obligations
      # Group obligations by their END date's tax year, not start: a calendar Q1
      # starts 1 April, which by the 6 April rule would misclassify into the
      # prior year — its end, 30 June, puts it in the right one.
      tax_year = Hmrc::TaxYear.label(quarter_end)
      earliest = obligations.select { |ob| Hmrc::TaxYear.label(ob[:end_date]) == tax_year }
                            .map { |ob| ob[:start_date] }
                            .min
      earliest || Hmrc::TaxYear.start_date(quarter_end)
    end

    def safe_obligations
      client.obligations(scheme: hmrc_scheme_name)
    rescue => e
      Rails.logger.warn "Cumulative start lookup failed for #{entity.code} #{scheme}: #{e.message}"
      []
    end

    # Asked of the group, never rebuilt here. The group defines which accounts
    # make one submission, and a second copy of that query could drift from it —
    # silently and financially, as figures filed that the report never showed.
    #
    # For the window actually being filed: the scheme's active accounts plus any
    # inactive one with activity in it, so a figure the report shows is a figure
    # the return carries. Memoised per window, because a submission touches it
    # several times.
    def scheme_accounts(from, to)
      (@scheme_accounts ||= {})[[ from, to ]] ||= group.accounts_for_period(from: from, to: to).to_a
    end

    def build_breakdown(start_date, end_date)
      Reports::TaxCsv.new(
        accounts:         scheme_accounts(start_date, end_date),
        entity:           entity,
        scheme:           scheme,
        start_date:       start_date,
        end_date:         end_date,
        display_currency: submission_currency,
        admin:            admin
      ).breakdown_data
    end

    # Renders the submission HTML in-request, which needs view context, then
    # hands storage and email to a background job so the irreversible HMRC call
    # has already returned. Rescued so a render failure cannot undo a successful
    # submission; ArchiveAndNotifyJob retries storage and mail failures, landing
    # a genuine failure in solid_queue_failed_executions rather than losing the
    # record silently.
    def render_and_enqueue_archive(start_d, end_d, accounts, view_url, &renderer)
      breakdown = Reports::TaxCsv.new(
        accounts:         accounts,
        entity:           entity,
        scheme:           scheme,
        start_date:       start_d,
        end_date:         end_d,
        display_currency: submission_currency,
        admin:            admin
      ).breakdown_data

      filename = Filing::Storage.filename_for(entity: entity, scheme: scheme, period_end: end_d, group: "MTD")
      html     = renderer.call(
        entity:       entity,
        scheme:       scheme,
        start_d:      start_d,
        end_d:        end_d,
        submitted_at: Time.current,
        currency:     submission_currency,
        breakdown:    breakdown
      )

      Filing::ArchiveAndNotifyJob.perform_later(
        entity_id:  entity.id,
        admin_id:   admin.id,
        scheme:     scheme,
        start_date: start_d,
        end_date:   end_d,
        view_url:   view_url,
        filename:   filename,
        html:       html,
        locale:     I18n.locale.to_s
      )
    rescue => e
      Rails.logger.error "HMRC post-submission enqueue failed for #{entity.code} #{scheme}: #{e.message}"
    end
  end
end
