# frozen_string_literal: true
require "test_helper"

class FilingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @entity = entities(:personal)
    sign_in_as(admins(:sudo))
  end

  # Permission and the taxpayer's number live on a taxpayer record owned by an
  # admin; the business id lives on the tax report group being filed. Filing
  # reaches both through the group, never through the entity.
  def connect!(entity, scheme: "gb_self_employment", expires_at: 1.hour.from_now,
               admin: admins(:sudo), business_id: "XBIS1")
    taxpayer = admin.taxpayers.create!(
      authority: "hmrc", label: "Test taxpayer",
      access_token: "tok", refresh_token: "ref", token_expires_at: expires_at
    )
    taxpayer.set_identifier(:nino, "AB123456C")
    taxpayer.save!

    group = entity.report_groups.find_or_initialize_by(tax_scheme: scheme)
    group.name = scheme
    group.update!(taxpayer: taxpayer, business_id: business_id)
    taxpayer
  end

  # ── connect ────────────────────────────────────────────────────────────────

  test "connect redirects to HMRC authorization URL" do
    Hmrc::Oauth.stub(:authorization_url, "https://hmrc.example.com/oauth") do
      get filing_connect_entity_path(@entity, locale: :en, connector: "hmrc_mtd")
      assert_response :redirect
      assert_redirected_to "https://hmrc.example.com/oauth"
    end
  end

  test "connect stores state and entity in session" do
    Hmrc::Oauth.stub(:authorization_url, "https://hmrc.example.com/oauth") do
      get filing_connect_entity_path(@entity, locale: :en, connector: "hmrc_mtd")
      assert session[:filing_oauth_state].present?
      assert_equal @entity.id, session[:filing_oauth_entity_id]
      assert_equal "hmrc_mtd",  session[:filing_oauth_type]
    end
  end

  test "connect rejects unknown connector" do
    get filing_connect_entity_path(@entity, locale: :en, connector: "unknown_type")
    assert_redirected_to edit_tax_entity_path(@entity, locale: :en)
  end

  # HMRC allows only FIVE registered redirect URIs. A locale segment means one
  # slot per language — four of five spent, and the next language added would
  # break OAuth for everyone using it. The URI must stay locale-free.
  test "the callback URI given to HMRC carries no locale" do
    captured = nil
    recorder = Object.new
    recorder.define_singleton_method(:authority) { "HMRC" }
    recorder.define_singleton_method(:connect_url) do |callback_uri:, state:|
      captured = callback_uri
      "https://hmrc.example.com/oauth"
    end

    Filing::Base.stub(:for, recorder) do
      get filing_connect_entity_path(@entity, locale: :de, connector: "hmrc_mtd")
    end

    assert captured, "connect should have built a callback URI"
    # Asserted against what the CONNECTOR declares, not against a literal. A
    # redirect URI differing from the registered one by a single character is
    # refused, so the invariant worth testing is "we send exactly what we
    # registered" — which stays true when the registered path changes, where a
    # literal would not.
    assert_match %r{#{Regexp.escape(Filing::HmrcMtd::REGISTERED_CALLBACK_PATH)}\z}, captured
    refute_match %r{/(en|de|nl|es)/entities/}, captured,
                 "a locale in the URI would spend one of HMRC's five registration slots per language"
  end

  # …which means the language has to survive the round trip in the session.
  test "connect remembers the locale so the callback can restore it" do
    Hmrc::Oauth.stub(:authorization_url, "https://hmrc.example.com/oauth") do
      get filing_connect_entity_path(@entity, locale: :de, connector: "hmrc_mtd")
      assert_equal "de", session[:filing_oauth_locale]
    end
  end

  # ── callback ───────────────────────────────────────────────────────────────

  test "callback redirects to dashboard on state mismatch" do
    get filing_callback_entities_path(locale: :en, state: "bad_state", code: "abc")
    assert_redirected_to dashboard_path(locale: :en)
  end

  test "callback exchanges code and redirects to edit_tax" do
    @taxpayer = admins(:sudo).taxpayers.create!(authority: "hmrc", label: "Me")
    # Drive connect first so the session is set via controller (not direct
    # assignment)
    Hmrc::Oauth.stub(:authorization_url, "https://hmrc.example.com/oauth") do
      get filing_connect_entity_path(@entity, locale: :en, connector: "hmrc_mtd",
                                         taxpayer_id: @taxpayer.id)
    end
    state = session[:filing_oauth_state]
    assert state.present?, "connect should have stored state in session"

    mock_result = { access_token: "tok", refresh_token: "ref", expires_in: 3600 }

    Hmrc::Oauth.stub(:exchange_code, mock_result) do
      get filing_callback_entities_path(locale: :en, state: state, code: "abc")
    end
    assert_redirected_to edit_tax_entity_path(@entity, locale: :en)
    assert_equal "tok", @taxpayer.reload.access_token
  end

  # The token belongs to a taxpayer, so the callback must know WHICH — an admin
  # may hold several taxpayers at one authority.
  test "a callback with no taxpayer in session stores nothing" do
    Hmrc::Oauth.stub(:authorization_url, "https://hmrc.example.com/oauth") do
      get filing_connect_entity_path(@entity, locale: :en, connector: "hmrc_mtd")
    end
    state = session[:filing_oauth_state]

    Hmrc::Oauth.stub(:exchange_code, { access_token: "tok", expires_in: 3600 }) do
      get filing_callback_entities_path(locale: :en, state: state, code: "abc")
    end
    assert_redirected_to edit_tax_entity_path(@entity, locale: :en)
    assert flash[:alert].present?
  end

  # ── disconnect ─────────────────────────────────────────────────────────────

  test "disconnect clears the permission and keeps the taxpayer's number" do
    taxpayer = connect!(@entity)

    delete filing_disconnect_entity_path(@entity, locale: :en, connector: "hmrc_mtd",
                                             taxpayer_id: taxpayer.id)
    assert_redirected_to edit_tax_entity_path(@entity, locale: :en)

    taxpayer.reload
    assert_nil taxpayer.access_token
    assert_nil taxpayer.refresh_token
    # The number is the person's, not the session's — they need it to reconnect.
    assert_equal "AB123456C", taxpayer.identifier(:nino)
  end

  # ── periods ────────────────────────────────────────────────────────────────

  test "periods renders with stub obligations" do
    @entity.update!(tax_schemes: ["gb_self_employment"])
    connect!(@entity)

    # Use fulfilled periods only — avoids triggering build_breakdown for preview
    stub_obs = [
      { start_date: Date.new(2024, 4, 6), end_date: Date.new(2024, 7, 5),
        due_date: Date.new(2024, 8, 5), status: Filing::Base::STATUS_FULFILLED, period_id: "2024-04-06_2024-07-05" }
    ]
    mock_client = Object.new
    mock_client.define_singleton_method(:obligations) { |**_| stub_obs }

    Hmrc::Oauth.stub(:ensure_fresh!, nil) do
      Hmrc::Client.stub(:for_group, mock_client) do
        get filing_periods_entity_path(@entity, locale: :en, scheme: "gb_self_employment")
        assert_response :success
      end
    end
  end

  # The preview block is the one the other periods test deliberately avoids,
  # since it uses fulfilled-only obligations so build_breakdown never runs —
  # which left _preview rendered by nothing. Every string in it names the
  # authority.
  test "the preview block renders, naming the authority rather than HMRC" do
    @entity.update!(tax_schemes: [ "gb_self_employment" ])
    connect!(@entity)

    ob = { start_date: Date.new(2026, 4, 6), end_date: Date.new(2026, 7, 5),
           due_date: Date.new(2026, 8, 5), status: Filing::Base::STATUS_OPEN, period_id: "2026-04-06_2026-07-05" }
    preview = { obligation: ob, period_start: ob[:start_date],
                breakdown: { income: [], expenses: [], other: [],
                             total_income: 0, total_expenses: 0, net: 0 } }

    mock_filing = Object.new
    mock_filing.define_singleton_method(:authority) { "HMRC" }
    mock_filing.define_singleton_method(:panel_partial) { nil }
    mock_filing.define_singleton_method(:periods) do
      { obligations: [ ob ], preview: preview, error: nil }
    end

    Filing::Base.stub(:for, mock_filing) do
      get filing_periods_entity_path(@entity, locale: :en, scheme: "gb_self_employment")
    end

    assert_response :success
    assert_includes @response.body, "HMRC"
  end

  # The error branch too — three of its four strings interpolate the authority,
  # and a missing argument raises rather than degrading.
  test "the connection-error block renders" do
    @entity.update!(tax_schemes: [ "gb_self_employment" ])
    connect!(@entity)

    mock_filing = Object.new
    mock_filing.define_singleton_method(:authority) { "HMRC" }
    mock_filing.define_singleton_method(:panel_partial) { nil }
    mock_filing.define_singleton_method(:periods) do
      { obligations: [], preview: nil, error: "token expired" }
    end

    Filing::Base.stub(:for, mock_filing) do
      get filing_periods_entity_path(@entity, locale: :en, scheme: "gb_self_employment")
    end

    assert_response :success
    assert_includes @response.body, "token expired"
  end

  test "periods redirects on invalid scheme" do
    @entity.update!(tax_schemes: ["gb_self_employment"])
    connect!(@entity)
    get filing_periods_entity_path(@entity, locale: :en, scheme: "gb_property")
    assert_redirected_to edit_tax_entity_path(@entity, locale: :en)
  end

  # ── submit ─────────────────────────────────────────────────────────────────

  test "submit sets the print flag and redirects to periods" do
    @entity.update!(tax_schemes: ["gb_self_employment"])
    connect!(@entity)

    mock_filing = Object.new
    mock_filing.define_singleton_method(:authority) { "HMRC" }
    mock_filing.define_singleton_method(:panel_partial) { nil }
    mock_filing.define_singleton_method(:submit) { |period_id:, view_url:, &_blk| }

    Filing::Base.stub(:for, mock_filing) do
      post filing_submit_entity_path(@entity, locale: :en),
           params: { scheme: "gb_self_employment", period_id: "2024-04-06_2024-07-05" }
    end

    assert_redirected_to filing_periods_entity_path(@entity, locale: :en, scheme: "gb_self_employment")
    assert_equal "2024-04-06_2024-07-05", flash[:submitted_period_id]
    assert flash[:notice].present?
  end

  # ── view ───────────────────────────────────────────────────────────────────

  test "view renders the stored submission with CSP disabled" do
    @entity.update!( tax_schemes: ["gb_self_employment"])
    html = "<!DOCTYPE html><html><head><style>body{color:#333}</style></head>" \
           "<body>Stored submission</body></html>"

    Filing::Storage.stub(:fetch_html, html) do
      get filing_view_entity_path(@entity, locale: :en, scheme: "gb_self_employment",
                                      period_id: "2024-04-06_2024-07-05")
      assert_response :success
      assert_includes @response.body, "Stored submission"
      # Inline <style> must not be blocked — CSP is disabled for this action.
      assert_nil @response.headers["Content-Security-Policy"]
    end
  end

  test "view for an XHR (dialog) request strips the document chrome and inline style" do
    @entity.update!( tax_schemes: ["gb_self_employment"])
    html = "<!DOCTYPE html><html><head><style>body{color:#333}</style></head>" \
           "<body><header>Head</header><table><tr><td>Row</td></tr></table></body></html>"

    Filing::Storage.stub(:fetch_html, html) do
      get filing_view_entity_path(@entity, locale: :en, scheme: "gb_self_employment",
                                      period_id: "2024-04-06_2024-07-05"),
          headers: { "X-Requested-With" => "XMLHttpRequest" }
      assert_response :success
      assert_includes @response.body, "<header>Head</header>"
      assert_includes @response.body, "<table>"
      # The inline <style> that would trip the page CSP, and the document
      # wrapper, must be gone.
      refute_includes @response.body, "<style"
      refute_includes @response.body, "<!DOCTYPE"
    end
  end

  test "view is reachable with a valid signed token and no session" do
    @entity.update!( tax_schemes: ["gb_self_employment"])
    sign_out # emailed link is opened without a logged-in session

    token = FilingController.view_token(
      entity_id: @entity.id, scheme: "gb_self_employment",
      period_id: "2024-04-06_2024-07-05"
    )

    Filing::Storage.stub(:fetch_html, "<html><body>Tokened submission</body></html>") do
      get filing_view_entity_path(@entity, locale: :en, sgid: token)
      assert_response :success
      assert_includes @response.body, "Tokened submission"
    end
  end

  test "view with an invalid token and no session is not found" do
    @entity.update!( tax_schemes: ["gb_self_employment"])
    sign_out

    get filing_view_entity_path(@entity, locale: :en, scheme: "gb_self_employment",
                                    period_id: "2024-04-06_2024-07-05", sgid: "tampered")
    assert_response :not_found
  end

  test "view without a token or session is not found" do
    @entity.update!( tax_schemes: ["gb_self_employment"])
    sign_out

    get filing_view_entity_path(@entity, locale: :en, scheme: "gb_self_employment",
                                    period_id: "2024-04-06_2024-07-05")
    assert_response :not_found
  end

  test "periods response still carries a CSP header" do
    # Control: confirms the view exemption is specific, not app-wide.
    @entity.update!(tax_schemes: ["gb_self_employment"])
    connect!(@entity)
    mock_client = Object.new
    mock_client.define_singleton_method(:obligations) { |**_| [] }

    Hmrc::Oauth.stub(:ensure_fresh!, nil) do
      Hmrc::Client.stub(:for_group, mock_client) do
        get filing_periods_entity_path(@entity, locale: :en, scheme: "gb_self_employment")
        assert @response.headers["Content-Security-Policy"].present?
      end
    end
  end

  # ── access control ─────────────────────────────────────────────────────────

  test "non-sudo with edit access can reach periods" do
    sign_out
    sign_in_as(admins(:two))
    entity = entities(:family_biz)
    entity.update!(tax_schemes: ["gb_self_employment"])
    connect!(entity, admin: admins(:two))

    mock_client = Object.new
    mock_client.define_singleton_method(:obligations) { |**_| [] }

    Hmrc::Oauth.stub(:ensure_fresh!, nil) do
      Hmrc::Client.stub(:for_group, mock_client) do
        get filing_periods_entity_path(entity, locale: :en, scheme: "gb_self_employment")
        assert_response :success
      end
    end
  end
end

# Filing → report: opens the scheme's report over the period HMRC asked for, so
# "what is in this figure?" can be answered at account level, which a submission
# of twenty totals never shows.
class FilingReportLinkTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(admins(:sudo))
    @entity = Entity.create!(code: "92", name: "Filing Link", active: true,
                                  tax_schemes: [ "gb_self_employment" ])
    @group  = @entity.report_groups.create!(name: "gb_self_employment",
                                            tax_scheme: "gb_self_employment")
  end

  test "creates a report over the submitted period, with the name you gave it" do
    period = "2026-04-06_2026-07-05"

    assert_difference "Report.count", 1 do
      post filing_report_entity_url(@entity, locale: :en),
           params: { scheme: "gb_self_employment", period_id: period, name: "Q1 26/27" }
    end
    report = Report.order(:id).last
    assert_redirected_to report_path(report, locale: :en)
    assert_equal @group, report.report_group
    assert_equal "Q1 26/27", report.name
    assert_equal Date.new(2026, 7, 5), report.end_date

    # asking twice for one period must not leave two behind
    assert_no_difference "Report.count" do
      post filing_report_entity_url(@entity, locale: :en),
           params: { scheme: "gb_self_employment", period_id: period, name: "again" }
    end
  end

  # It writes, so following a link must not do it. Reports used to appear that
  # nobody had asked for, named after their own date range.
  test "a GET cannot create a report" do
    assert_no_difference "Report.count" do
      get filing_report_entity_url(@entity, locale: :en,
                                       scheme: "gb_self_employment", period_id: "2026-04-06_2026-07-05")
    end
    refute_equal 302, response.status, "a link must not reach an action that writes"
  end

  test "an unnamed report falls back to its dates" do
    post filing_report_entity_url(@entity, locale: :en),
         params: { scheme: "gb_self_employment", period_id: "2026-04-06_2026-07-05", name: "  " }
    assert_match(/2026/, Report.order(:id).last.name)
  end

  test "bounces back when the scheme has no tax report group" do
    @group.destroy!
    post filing_report_entity_url(@entity, locale: :en),
         params: { scheme: "gb_self_employment", period_id: "2026-04-06_2026-07-05", name: "X" }
    assert_redirected_to filing_periods_entity_path(@entity, locale: :en, scheme: "gb_self_employment")
  end
end
