# frozen_string_literal: true

class ReportsController < BaseController
  before_action :set_report, only: [:show, :edit, :update, :destroy, :tax_export, :download_tax_export_backup]
  # Reports and closes belong to an entity; changing them is a write into it.
  # tax_export is deliberately NOT here — a read_only admin may export, the one
  # write-shaped thing their level allows.
  before_action :require_writable_report,           only: [:edit, :update, :destroy]
  before_action :require_writable_report_group_param, only: [:new, :create]
  before_action :require_writable_year_end_entity,  only: [:new_year_end, :change_year_end, :create_year_end]

  # Which published series produced the converted column — see #rate_sources.
  helper_method :rate_sources
  # What the converted column is showing, currency AND series — see
  # Reports::DisplayChoice.
  helper_method :display_choice

  # Saved reports and downloadable archives share this page. Archives have no
  # table of their own (see Archives::Storage), so both sides are normalised to
  # Reports::Row and merged before pagination, in Ruby rather than SQL.
  #
  # That drops the DB-level LIMIT/OFFSET. Deliberate: a self-hosted install's
  # total report count stays in the hundreds over years of use, not the
  # unbounded kind of collection this app is otherwise careful never to load
  # whole.
  def index
    reports = accessible_reports.eager_load(report_group: :entity).map { |r| Reports::Row.from_report(r) }
    # One listing call per tax report on the page — fine at the sizes this app
    # actually runs at, same note as the pagination above.
    reports.each { |row| row.tax_export_backups = TaxExportStorage.list(row.report.id) if row.report.tax_report? }

    combined = (reports + archive_rows).sort_by { |r| [ r.period_end, r.period_start.to_s ] }.reverse
    @pagy, @rows = pagy(combined, limit: 25)
  end

  # The manual snapshot: this scope's current calendar year, up to today.
  # Deletable — a convenience copy, not the permanent record the year-end
  # archive is. One click both generates AND downloads.
  def create_archive
    entity = current_admin.accessible_entities.find_by(id: params[:entity_id])
    return deny_write unless entity

    scope_key = Archives::Storage.scope_key_for(entity)
    # A family archive is the whole family's ledger, not just this entity's —
    # see Admin#can_use_archive?. A no-op for a solo entity, whose entity came
    # from accessible_entities already.
    return deny_write unless current_admin.can_use_archive?(scope_key)

    csv = Archives::BooksCsv.new(scope_key: scope_key, year: Date.current.year, through: Date.current).generate
    if csv.lines.count <= 1 # header only
      redirect_to reports_path, alert: t("reports.index.nothing_to_archive")
      return
    end

    key = Archives::Storage.key_for(scope_key, Date.current)
    Archives::Storage.upload(key, csv)

    send_data csv, filename: File.basename(key), type: "text/csv", disposition: "attachment"
  end

  # key is scope_key/filename (see routes.rb) — the archives/ prefix is added
  # back here, not carried in the URL.
  #
  # Not deny_write: the route sets format: false so ".csv" survives as part of
  # the key instead of being parsed off as a response format, but that also
  # leaves request.format unresolved, so deny_write's respond_to falls through
  # to format.any and heads :forbidden instead of redirecting.
  def download_archive
    # parse_request_key, never params[:key] concatenated. Authorising the first
    # segment and then joining the rest was a traversal: "10/../05/…" passed as
    # "10" and read 05's whole ledger.
    parsed = Archives::Storage.parse_request_key(params[:key])
    return redirect_to(reports_path, alert: t("reports.index.not_found")) unless parsed
    scope_key, key = parsed

    # A family archive is the whole family's ledger in one file, posting-level
    # — access to one member is not access to the rest. See
    # Admin#can_use_archive?.
    unless current_admin.can_use_archive?(scope_key)
      redirect_to dashboard_path, alert: t("access.read_only_deny")
      return
    end

    send_data Archives::Storage.read(key),
      filename: File.basename(key), type: "text/csv", disposition: "attachment"
  rescue Shrine::FileNotFound, Errno::ENOENT, Aws::S3::Errors::NoSuchKey
    redirect_to reports_path, alert: t("reports.index.not_found")
  end

  # Deletable unless it is a year-end archive — the permanent record of an
  # actual closing event, not a convenience copy, so it is refused server-side
  # regardless of what the button shows. Write access, not just read: this is
  # destructive.
  #
  # Not deny_write, for the same reason as download_archive.
  def destroy_archive
    # ⚠️ Same traversal as download_archive had, and worse here — it DELETED
    # another entity's archive. See Archives::Storage.parse_request_key.
    parsed = Archives::Storage.parse_request_key(params[:key])
    return redirect_to(reports_path, alert: t("reports.index.not_found")) unless parsed
    scope_key, key = parsed

    unless Entity.where(id: current_admin.writable_entity_ids).any? { |e| Archives::Storage.scope_key_for(e) == scope_key }
      redirect_to dashboard_path, alert: t("access.read_only_deny")
      return
    end

    entry = Archives::Storage.entry_for(key)
    if entry&.year_end
      redirect_to reports_path, alert: t("reports.index.cannot_delete_year_end")
      return
    end

    Archives::Storage.delete(key)
    redirect_to reports_path, notice: t("reports.index.archive_deleted")
  end

  def show
    # A tax report totals into the currency its scheme files in — not the
    # admin's preference, and not theirs to change.
    #
    # It forfeits the SOURCE choice with it: a custom report may be read at any
    # accepted series because it is management information, but a tax report's
    # series is the one its country's law names, and switching it would show a
    # figure that cannot be filed. display_currency is set only on a tax group,
    # so its presence is the test for both.
    forced = @report.report_group.display_currency
    @display_currency = forced || display_choice.currency
    @display_sources  = forced ? nil : display_choice.sources
    # What a link back to this view must carry — NOT @display_currency, which is
    # the currency alone, so every CSV link threw the chosen SOURCE away:
    # picking CHF (ESTV) on screen and downloading gave a file built from ECB
    # rates.
    @display_param    = forced || display_choice.to_param
    # A tax report's series is its country's law and is not ours to re-decide;
    # an ordinary saved report picks one for its whole period like any other.
    resolve_display_source!(@report.start_date, @report.end_date) unless forced
    @short_version = params[:version] != 'long'

    @rates_available = true
    presenter_class = @report.tax_report? ? Reports::TaxReport : Reports::CustomReport
    empty = { report: @report, display_currency: @display_currency, currencies: [],
              account_type_groups: [], category_groups: [] }

    @data = with_rates(empty) do
      presenter_class.new(
        report: @report,
        display_currency: @display_currency,
        short_version: @short_version,
        admin: current_admin,
        sources: @display_sources
      ).generate
    end

    # CustomReport catches a missing rate internally so the per-currency
    # figures survive, and reports it here rather than raising.
    note_missing_rate(@data[:rate_unavailable]) if @data[:rate_unavailable]

    @fx_variance = with_rates(0) do
      ExchangeRate.calculate_fx_variance(
        from_date: @report.start_date,
        to_date: @report.end_date,
        display_currency: @display_currency,
        admin: current_admin,
        entity_codes: [@report.report_group.entity.code],
        source: @effective_source
      )
    end
    
    @currencies_with_data = @data[:currencies]
    @currencies = report_currencies
    @currency_options = currency_options
    # A saved report builds its own translators inside CustomReport and never
    # goes through #run_totals, so without this the source note is absent on
    # exactly the reports most likely to be filed.
    @rate_sources = @data[:rate_sources]

    respond_to do |format|
      format.html
      format.csv do
        # One CSV per report, mirroring the screen: a tax report is the
        # categorised view (the same figures the submission carries), a custom
        # report the account list. Summary or detail follows the short/long
        # toggle in both cases.
        if @report.tax_report?
          group = @report.report_group
          csv = Reports::TaxReportCsv.new(
            report:           @report,
            data:             @data,
            display_currency: @display_currency,
            short_version:    @short_version
          ).generate
          send_data csv,
            filename: "#{group.tax_scheme}-#{group.entity.code}-#{@report.start_date}-#{@report.end_date}-#{@short_version ? 'summary' : 'detail'}.csv"
        else
          csv = Reports::StandardCsv.new(
                report: @report,
                data: @data,
                display_currency: @display_currency,
                short_version: @short_version
              ).generate
          send_data csv, filename: "#{@report.name.parameterize}-#{@short_version ? 'short' : 'long'}.csv"
        end
      end
    end
  end

  # always from modal (dashboard and report group)
  def new
    @report_group = accessible_report_groups.find(params[:report_group_id])
    @report = Report.new(start_date: Date.current.beginning_of_year, end_date: Date.current)
  end

  def create
    @report_group = accessible_report_groups.find(params[:report_group_id])
    @report = @report_group.reports.build(report_params)
    if @report.save
      redirect_to dashboard_path, notice: t("reports.created")
    else
      load_form_data
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    load_form_data
  end

  def update
    if @report.update(report_params)
      redirect_to report_path(@report), notice: t("reports.updated")
    else
      load_form_data
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @report.destroy
    redirect_to reports_path, notice: t("reports.deleted")
  end

  def tax_export
    entity = @report.report_group.entity

    # Everything the job needs it reads off the report itself — account set,
    # dates, scheme and filing currency. A custom report may override the
    # display currency; a tax report's is the scheme's and is ignored.
    TaxExportJob.perform_later(
      admin_id: current_admin.id,
      report_id: @report.id,
      locale: I18n.locale.to_s,
      display_currency: params[:currency].presence || default_display_currency
    )

    # Notify whoever actually holds full access on THIS entity. There can be
    # more than one on a shared entity, so each gets their own copy rather than
    # guessing which one is "the" owner.
    if read_only_admin?
      entity.admin_entities.with_full_access.includes(:admin).each do |ae|
        AdminMailer.with(
          parent_admin: ae.admin,
          coadmin: current_admin,
          entity: entity,
          start_date: @report.start_date,
          end_date: @report.end_date,
          locale: I18n.locale.to_s
        ).tax_export_triggered_by_coadmin.deliver_later
      end
    end

    redirect_to report_path(@report), notice: t("reports.tax_export_started")
  end

  # key is just the filename (see routes.rb) — the tax_exports/<id>/ prefix is
  # added back here, never carried in the URL. @report is already authorised by
  # set_report, so — unlike Archives::Storage, which has no record of its own to
  # authorise against — the only thing left to check is that the filename is one
  # this app actually writes.
  def download_tax_export_backup
    filename = params[:key].to_s
    unless filename.match?(TaxExportStorage::FILENAME_FORMAT)
      return redirect_to(reports_path, alert: t("reports.index.not_found"))
    end

    key = "#{TaxExportStorage::PREFIX}/#{@report.id}/#{filename}"
    send_data TaxExportStorage.read(key),
      filename: filename, type: "text/csv", disposition: "attachment"
  rescue Shrine::FileNotFound, Errno::ENOENT, Aws::S3::Errors::NoSuchKey
    redirect_to reports_path, alert: t("reports.index.not_found")
  end

  def trial_balance
    @start_date = params[:start_date]&.to_date || default_period_start
    @end_date = params[:end_date]&.to_date || Date.current
    @display_currency = display_choice.currency
    @display_sources  = display_choice.sources
    @display_param    = display_choice.to_param
    resolve_display_source!(@start_date, @end_date)
    # A trial balance only balances at the family level — pull in the whole
    # consolidation family of any selected member.
    @selected_entity_codes = Entity.family_codes_for(params[:entities]&.split(',') || default_entity_codes)

    @accounts = accessible_accounts.active
      .leaf_accounts
      .for_entity_codes(@selected_entity_codes)
      .order(:code)
    account_ids = @accounts.pluck(:id)

    # Fetch data grouped by month for proper exchange rate translation
    @balances_by_currency, @balances_by_month = fetch_trial_balance_data_by_month(account_ids, start_date: @start_date, end_date: @end_date, exclude_closing_entries: true)

    @accounts = @accounts.to_a

    @currencies_with_data = @balances_by_currency.values
      .flat_map(&:keys)
      .uniq
      .sort_by { |c| CurrencyConfig.sort_index(c) }

    @currencies = report_currencies
    @currency_options = currency_options
    @available_entities = available_entity_codes

    # Pre-calculate all translated values using per-month translators
    @rates_available = true
    @account_translated, @totals = with_rates([ {}, { debit_by_currency: {}, credit_by_currency: {},
                                                     translated_debit: 0, translated_credit: 0 } ]) do
      run_totals(Reports::TrialBalanceTotals.new(
        accounts:             @accounts,
        balances_by_currency: @balances_by_currency,
        balances_by_month:    @balances_by_month,
        display_currency:     @display_currency,
        currencies_with_data: @currencies_with_data,
        sources:              @display_sources
      ))
    end

    @fx_variance = with_rates(0) do
      ExchangeRate.calculate_fx_variance(
        from_date: @start_date,
        to_date: @end_date,
        display_currency: @display_currency,
        admin: current_admin,
        entity_codes: @selected_entity_codes,
        source: @effective_source
      )
    end

    # The translated Debit and Credit columns are each a sum of per-account,
    # per-month figures rounded one at a time, so the two need not tie even when
    # every journal entry balances in its own currency. That gap IS translation
    # variance — the cross-currency transfers itemised on the FX-variance page
    # are its larger part, sub-cent rounding the rest. Reporting the whole gap
    # on the one line makes the adjusted totals balance exactly rather than
    # leaving an unexplained difference.
    translated_gap = @totals[:translated_debit] - @totals[:translated_credit]
    @fx_variance = translated_gap unless translated_gap.zero? && @fx_variance.zero?

    # The FX variance lands on whichever side is short, so the adjusted totals
    # balance. Computed here rather than in the template: it is an accounting
    # figure, and it has to be identical in the CSV.
    @totals.merge!(adjusted_totals(@totals, @fx_variance))

    respond_to do |format|
      format.html
#        format.csv { send_data generate_trial_balance_csv, filename: "trial-
# balance-#{@end_date}.csv" }
      format.csv do
        csv = Reports::TrialBalanceCsv.new(
          data: {
            # nil unless a rate was missing; the exporter then drops the
            # converted column rather than filling it with zeros.
            rate_unavailable: @rate_unavailable,
            # Which series actually answered — see #rate_sources.
            rate_sources: rate_sources,
            accounts: @accounts,
            balances_by_currency: @balances_by_currency,
            account_translated: @account_translated,
            totals: @totals,
            currencies_with_data: @currencies_with_data
          },
          display_currency: @display_currency,
          end_date: @end_date,
          fx_variance: @fx_variance
        ).generate
        send_data csv, filename: "trial-balance-#{@end_date}.csv"
      end
    end
  end

  def profit_loss
    @start_date = params[:start_date]&.to_date || default_period_start
    @end_date = params[:end_date]&.to_date || Date.current
    @display_currency = display_choice.currency
    @display_sources  = display_choice.sources
    @display_param    = display_choice.to_param
    resolve_display_source!(@start_date, @end_date)
    # The standard P&L reports at the family level (per-entity drill-down is
    # what custom reports are for) — pull in the whole family of any member.
    @selected_entity_codes = Entity.family_codes_for(params[:entities]&.split(',') || default_entity_codes)

    all_accounts = accessible_accounts.active
      .leaf_accounts
      .for_entity_codes(@selected_entity_codes)
      .where(account_type: [:income, :expense])
      .order(:code)
      .to_a

    return render_empty_profit_loss if all_accounts.empty?

    # Fetch data grouped by month for proper exchange rate translation
    all_balances, @balances_by_month = fetch_balances_by_currency_and_month(all_accounts, start_date: @start_date, end_date: @end_date, exclude_closing_entries: true)

    @income_accounts = all_accounts.select(&:income?)
    @expense_accounts = all_accounts.select(&:expense?)

    @income_by_currency = {}
    @expense_by_currency = {}

    income_ids  = @income_accounts.map(&:id).to_set
    expense_ids = @expense_accounts.map(&:id).to_set

    all_balances.each do |account_id, currencies|
      if income_ids.include?(account_id)
        @income_by_currency[account_id] = currencies
      elsif expense_ids.include?(account_id)
        @expense_by_currency[account_id] = currencies
      end
    end

    @income_accounts = @income_accounts.select { |a| @income_by_currency.key?(a.id) }
    @expense_accounts = @expense_accounts.select { |a| @expense_by_currency.key?(a.id) }

    @currencies_with_data = (@income_by_currency.values + @expense_by_currency.values)
      .flat_map(&:keys)
      .uniq
      .sort_by { |c| CurrencyConfig.sort_index(c) }

    @currencies = report_currencies
    @currency_options = currency_options
    @available_entities = available_entity_codes

    # Pre-calculate all translated values using per-month translators
    @rates_available = true
    @account_translated, @totals = with_rates([ {}, {
      income_by_currency: Hash.new(0), expense_by_currency: Hash.new(0),
      net_by_currency: Hash.new(0),
      translated_income: 0, translated_expense: 0, translated_net: 0
    } ]) do
      run_totals(Reports::ProfitLossTotals.new(
        income_accounts:      @income_accounts,
        expense_accounts:     @expense_accounts,
        income_by_currency:   @income_by_currency,
        expense_by_currency:  @expense_by_currency,
        balances_by_month:    @balances_by_month,
        display_currency:     @display_currency,
        currencies_with_data: @currencies_with_data,
        sources:              @display_sources
      ))
    end

    # with_rates, like the other two. It was bare, which was harmless only
    # while a missing rate returned a wrong number instead of raising.
    @fx_variance = with_rates(0) do
      ExchangeRate.calculate_fx_variance(
        from_date: @start_date,
        to_date: @end_date,
        display_currency: @display_currency,
        admin: current_admin,
        entity_codes: @selected_entity_codes,
        source: @effective_source
      )
    end

    respond_to do |format|
      format.html
      format.csv do
        csv = Reports::ProfitLossCsv.new(
          data: {
            # nil unless a rate was missing; the exporter then drops the
            # converted column rather than filling it with zeros.
            rate_unavailable: @rate_unavailable,
            # Which series actually answered — see #rate_sources.
            rate_sources: rate_sources,
            income_accounts: @income_accounts,
            expense_accounts: @expense_accounts,
            income_by_currency: @income_by_currency,
            expense_by_currency: @expense_by_currency,
            account_translated: @account_translated,
            totals: @totals,
            currencies_with_data: @currencies_with_data
          },
          display_currency: @display_currency,
          start_date: @start_date,
          end_date: @end_date,
          fx_variance: @fx_variance
        ).generate
        send_data csv, filename: "profit-loss-#{@start_date}-to-#{@end_date}.csv"
      end
#        format.csv { send_data generate_profit_loss_csv, filename: "profit-
# loss-#{@start_date}-to-#{@end_date}.csv" }
    end
  end

  def balance_sheet
    @end_date = params[:end_date]&.to_date || Date.current
    @display_currency = display_choice.currency
    @display_sources  = display_choice.sources
    @display_param    = display_choice.to_param
    # A balance sheet stands at ONE date, so the period it must be covered
    # for is that month — there is no range to reach across.
    resolve_display_source!(@end_date, @end_date)
    # A balance sheet only balances at the family level — pull in the whole
    # consolidation family of any selected member.
    @selected_entity_codes = Entity.family_codes_for(params[:entities]&.split(',') || default_entity_codes)

    all_accounts = accessible_accounts.active
      .leaf_accounts
      .for_entity_codes(@selected_entity_codes)
      .where(account_type: [:asset, :liability, :equity])
      .order(:code)
      .to_a

    @balances_by_currency, _ = fetch_balances_by_currency_and_month(all_accounts, end_date: @end_date)

    @asset_accounts     = all_accounts.select(&:asset?).select     { |a| @balances_by_currency.key?(a.id) }
    @liability_accounts = all_accounts.select(&:liability?).select { |a| @balances_by_currency.key?(a.id) }
    @equity_accounts    = all_accounts.select(&:equity?).select    { |a| @balances_by_currency.key?(a.id) }

    @currencies_with_data = @balances_by_currency.values
      .flat_map(&:keys)
      .uniq
      .sort_by { |c| CurrencyConfig.sort_index(c) }

    @currencies = report_currencies
    @currency_options = currency_options
    @available_entities = available_entity_codes

    @rates_available = true
    @account_translated, @totals = with_rates([ {}, {
      asset_by_currency: Hash.new(0), liability_by_currency: Hash.new(0),
      equity_by_currency: Hash.new(0), liability_equity_by_currency: Hash.new(0),
      translated_assets: 0, translated_liabilities: 0, translated_equity: 0,
      translated_liability_equity: 0, net_profit: 0
    } ]) do
      run_totals(Reports::BalanceSheetTotals.new(
        asset_accounts:       @asset_accounts,
        liability_accounts:   @liability_accounts,
        equity_accounts:      @equity_accounts,
        balances_by_currency: @balances_by_currency,
        as_of:                @end_date,
        display_currency:     @display_currency,
        currencies_with_data: @currencies_with_data,
        sources:              @display_sources
      ))
    end

    # The residual (assets − liabilities − equity) labelled "net profit" is
    # really unclosed P&L PLUS the FX translation variance from cross-currency
    # transfers. Split it, so the profit figure means what it says. Cumulative
    # to the balance-sheet date, like the statement itself.
    @fx_variance = with_rates(0) do
      ExchangeRate.calculate_fx_variance(
        from_date: nil,
        to_date: @end_date,
        display_currency: @display_currency,
        admin: current_admin,
        entity_codes: @selected_entity_codes,
        source: @effective_source
      )
    end

    respond_to do |format|
      format.html
      format.csv do
        csv = Reports::BalanceSheetCsv.new(
          data: {
            # nil unless a rate was missing; the exporter then drops the
            # converted column rather than filling it with zeros.
            rate_unavailable: @rate_unavailable,
            # Which series actually answered — see #rate_sources.
            rate_sources: rate_sources,
            asset_accounts:     @asset_accounts,
            liability_accounts: @liability_accounts,
            equity_accounts:    @equity_accounts,
            balances_by_currency: @balances_by_currency,
            account_translated: @account_translated,
            totals:             @totals,
            fx_variance:        @fx_variance,
            currencies_with_data: @currencies_with_data
          },
          display_currency: @display_currency,
          end_date: @end_date
        ).generate
        send_data csv, filename: "balance-sheet-#{@end_date}.csv"
      end
    end
  end

  # The cross-currency transfers behind the "Exchange Rate Variance" line on the
  # balance sheet, P&L and trial balance — one row each, with the rate the
  # amounts imply against the published one, and the cents it contributed. Every
  # report links here with its own period and scope.
  def fx_variance
    @start_date = params[:start_date]&.to_date
    @end_date   = params[:end_date]&.to_date || Date.current
    @display_currency = display_choice.currency
    @display_sources  = display_choice.sources
    @display_param    = display_choice.to_param
    resolve_display_source!(@start_date || default_period_start, @end_date)
    @selected_entity_codes = Entity.family_codes_for(params[:entities]&.split(',') || default_entity_codes)

    @currencies = report_currencies
    @currency_options = currency_options
    @available_entities = available_entity_codes

    @rows = with_rates([]) do
      ExchangeRate.fx_variance_rows(
        from_date: @start_date,
        to_date: @end_date,
        display_currency: @display_currency,
        admin: current_admin,
        entity_codes: @selected_entity_codes,
        source: @effective_source
      )
    end
    @fx_variance = @rows.sum { |r| r[:variance_cents] }

    respond_to do |format|
      format.html
      format.csv do
        csv = Reports::FxVarianceCsv.new(
          rows: @rows, total: @fx_variance,
          display_currency: @display_currency,
          start_date: @start_date, end_date: @end_date
        ).generate
        send_data csv, filename: "exchange-rate-variance-#{@end_date}.csv"
      end
    end
  end

  # The financial-year page, and the only screen left in this flow: every close
  # is triggered by a native confirm on a button that POSTs to create_year_end.
  #
  # Two situations, same picker: no close yet, choose the pattern for the first;
  # already closing, change it, which reopens the closes it would move.
  def new_year_end
    @entity         = year_end_entity
    @closed_periods = closed_periods_for(@entity)
    # The pattern lives in the closing entries themselves, so "no pattern yet"
    # means no closed period, not "no retained-earnings account" — reopening
    # leaves those accounts behind, and they must not suppress the picker.
    @first_close    = @closed_periods.empty?
  end

  # Changing the financial year end means the existing closes no longer describe
  # the years the user wants, so they are removed and re-closed on the new
  # pattern using the ordinary close-forward button. Reported figures are
  # unaffected — P&L, trial balance and every tax export exclude closing
  # entries; only the balance sheet shows those years as unclosed again.
  def change_year_end
    @entity = year_end_entity
    reopened = Archives::Lock.with(Archives::Storage.scope_key_for(@entity)) { reopen_all_closes(@entity) }
    if reopened.zero?
      redirect_to new_year_end_reports_path(entity_id: @entity.id),
        alert: t("reports.year_end.nothing_to_reopen")
    else
      redirect_to new_year_end_reports_path(entity_id: @entity.id),
        notice: t("reports.year_end.reopened", count: reopened)
    end
  end

  def create_year_end
    @entity = year_end_entity
    period  = compute_fiscal_period

    unless period&.ready?
      redirect_to dashboard_path, alert: year_end_not_ready_alert(period)
      return
    end

    # Server-side defence: never close an unfinished year or an over-long span,
    # regardless of what the client submitted (it only ever chose a pattern).
    if period.end_date >= Date.current || (period.end_date - period.start_date).to_i > 366
      redirect_to dashboard_path, alert: t("reports.year_end.invalid_period")
      return
    end

    # Close and archive together under one lock on the scope — so a double
    # click, or two siblings closing at once, queue instead of racing (C1).
    Archives::Lock.with(Archives::Storage.scope_key_for(@entity)) do
      YearEndService.new(entity: @entity, start_date: period.start_date, end_date: period.end_date).call
      # Write any calendar year this close makes complete for the scope (the
      # last sibling), and refresh any already-written year it touched.
      Archives::YearEnd.after_close(@entity)
    end

    # If earlier years are still waiting, nudge the user to click again.
    notice = t("reports.year_end.entries_posted")
    notice = "#{notice} #{t('reports.year_end.more_to_close')}" if FiscalPeriod.next_for(@entity).ready?
    redirect_to dashboard_path, notice: notice
  rescue FiscalPeriod::InvalidYearEnd
    # A bad custom (Other) date — send them back to the picker to fix it.
    redirect_to new_year_end_reports_path(entity_id: @entity.id),
      alert: t("reports.year_end.invalid_year_end")
  rescue => e
    Rails.logger.error "YearEndService failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    redirect_to dashboard_path, alert: t("reports.year_end.error")
  end

  private

  # Distinct closed periods for this entity, newest first. One period may hold
  # several closing entries — one per currency — so they are counted as one.
  def closed_periods_for(entity)
    JournalEntry
      .where(closing_entry: true)
      .joins(postings: :account)
      .where("SUBSTRING(accounts.code, 2, 2) = ?", entity.code)
      .distinct
      .order(period_end: :desc)
      .pluck(:period_start, :period_end)
  end

  # Removes every closing entry of this entity, all periods and all currencies,
  # so the year end can be re-chosen; the user then closes forward again with
  # the ordinary button, which works oldest-first through the backlog.
  #
  # Returns the number of YEARS reopened, not entries — a single year holds one
  # closing entry per currency, and the user thinks in years.
  def reopen_all_closes(entity)
    years = closed_periods_for(entity).size
    return 0 if years.zero?

    Current.app_closing_entry_write = true
    ids = JournalEntry
      .where(closing_entry: true)
      .joins(postings: :account)
      .where("SUBSTRING(accounts.code, 2, 2) = ?", entity.code)
      .distinct
      .pluck(:id)
    JournalEntry.where(id: ids).destroy_all
    years
  ensure
    Current.app_closing_entry_write = false
  end

  def require_writable_report
    return if @report.nil?
    deny_write unless writable_reports.exists?(@report.id)
  end

  def require_writable_report_group_param
    deny_write unless writable_report_groups.exists?(params[:report_group_id])
  end

  # An entity the admin cannot write to and one that does not exist get the
  # same answer, deliberately: the refusal must not say which it was.
  def require_writable_year_end_entity
    entity = year_end_entity
    deny_write unless entity && current_admin.writable_entity_ids.include?(entity.id)
  end

  # find_by, not find: a bad or foreign entity_id is a permission answer
  # (require_writable_year_end_entity), not a 404. find raised inside the
  # action, where create_year_end's blanket rescue quietly turned it into the
  # generic year-end error.
  def year_end_entity
    @year_end_entity ||= if params[:entity_id].present?
      current_admin.accessible_entities.find_by(id: params[:entity_id])
    else
      current_admin.accessible_entities.first
    end
  end

  # One archive row per entity/family the admin can reach — families de-
  # duplicated by scope_key, so a member entity does not list the shared family
  # archive twice.
  def archive_rows
    seen = {}
    current_admin.accessible_entities.filter_map { |entity|
      scope_key = Archives::Storage.scope_key_for(entity)
      next if seen[scope_key]
      seen[scope_key] = true
      next unless current_admin.can_use_archive?(scope_key)

      label = entity.entity_group ? entity.entity_group.name : entity.name
      Archives::Storage.list(scope_key).map { |entry|
        Reports::Row.from_archive(entity_or_family_label: label, entity_code: entity.code, entry: entry)
      }
    }.flatten
  end

  # Flash for a period that can't be closed: "year isn't over yet" (dated) or
  # "nothing to close". Shared by new_year_end (GET) and create_year_end (POST).
  def year_end_not_ready_alert(period)
    if period&.not_finished?
      t("reports.year_end.not_finished",
        start: I18n.l(period.start_date, format: :short_date),
        finish: I18n.l(period.end_date, format: :short_date))
    else
      t("reports.year_end.nothing_to_close")
    end
  end

  # Next closeable period for @entity. A supplied pattern establishes the fiscal
  # year (the first close); otherwise the period is derived from the entity's
  # last closing entry.
  def compute_fiscal_period
    if params[:pattern].present?
      month, day = fiscal_year_end_from_params
      FiscalPeriod.next_for(@entity, pattern: params[:pattern], year_end_month: month, year_end_day: day)
    else
      FiscalPeriod.next_for(@entity)
    end
  end

  # For the "other" pattern, the recurring year-end as a day and month, no year.
  # Impossible combinations (31 April, 29 Feb) are caught downstream when the
  # period date is built.
  def fiscal_year_end_from_params
    return [nil, nil] unless params[:pattern] == "other"

    month = params[:year_end_month].to_i
    day   = params[:year_end_day].to_i
    raise FiscalPeriod::InvalidYearEnd unless (1..12).cover?(month) && (1..31).cover?(day)

    [month, day]
  end

  def set_report
    @report = accessible_reports.find(params[:id])
  end

  # No account_ids: a report does not own accounts — Report#accounts delegates
  # to its group's accounts_scope, so there is no account_ids= writer to assign
  # to, and permitting it meant a forged field would raise rather than be
  # ignored.
  def report_params
    params.require(:report).permit(:name, :start_date, :end_date, :report_group_id)
  end

  def load_form_data
    @account_options = accessible_accounts.active.order(:code)
      .pluck(:code, :name, :id)
      .map { |code, name, id| ["#{code} - #{name}", id] }
    @report_groups = accessible_report_groups.order(:name).pluck(:name, :id)
  end

  def default_period_start
    last_closing = accessible_journal_entries
      .joins(postings: :account)
      .where(posted: true)
      .where(accounts: { locked: true })
      .maximum(:entry_date)
    last_closing ? last_closing + 1.day : Date.current.beginning_of_year
  end

  def default_entity_codes
    accessible_entities.active.pluck(:code)
  end

  def available_entity_codes
    accessible_entities.active.pluck(:code, :name)
  end
  
  # [balances_by_currency, balances_by_month] — { account_id => { currency =>
  # balance } } and { account_id => { month => { currency => balance } } }, the
  # shapes the P&L and balance-sheet flows expect. A reshape of
  # Reports::LedgerBalances.
  def fetch_balances_by_currency_and_month(accounts, start_date: nil, end_date: Date.current, exclude_closing_entries: false)
    return [{}, {}] if accounts.empty?

    by_month = Reports::LedgerBalances.new(
      accounts: accounts, from: start_date, to: end_date,
      bucket: :month, include_closing: !exclude_closing_entries
    ).call

    by_currency = {}
    by_month.each do |account_id, buckets|
      per_currency = Hash.new(0)
      buckets.each_value { |by_curr| by_curr.each { |cur, amt| per_currency[cur] += amt } }
      by_currency[account_id] = per_currency.to_h
    end

    [ by_currency, by_month ]
  end

  # [balances_by_currency, balances_by_month] with debit and credit kept apart —
  # the shape the trial balance flow expects. A reshape of
  # Reports::LedgerBalances with net: false.
  def fetch_trial_balance_data_by_month(account_ids, start_date: nil, end_date: Date.current, exclude_closing_entries: false)
    return [{}, {}] if Array(account_ids).empty?

    by_month = Reports::LedgerBalances.new(
      account_ids: account_ids, from: start_date, to: end_date,
      bucket: :month, include_closing: !exclude_closing_entries, net: false
    ).call

    by_currency = {}
    by_month.each do |account_id, buckets|
      per_currency = Hash.new { |h, k| h[k] = { debit: 0, credit: 0 } }
      buckets.each_value do |by_curr|
        by_curr.each { |cur, sides| per_currency[cur][:debit] += sides[:debit]; per_currency[cur][:credit] += sides[:credit] }
      end
      by_currency[account_id] = per_currency.to_h
    end

    [ by_currency, by_month ]
  end

  # Which entity an account belongs to — digits 2-3 of its code, the same key
  # for_entity_codes uses. One query for the whole report.
  #
  # An entity's own rate applies to its own accounts whatever else is on the
  # page, including inside a consolidated family report.
  def entity_id_for(account)
    @entity_ids_by_code ||= Entity.pluck(:code, :id).to_h
    @entity_ids_by_code[account.code[1, 2]]
  end

  # Translation is the only part of a report that can fail: the per-currency
  # figures come straight from the ledger, while the translated column depends
  # on a published rate existing. So a missing rate costs the translated
  # column, not the page — and never silently becomes a rate of 1.0, which
  # converted every figure one-for-one and looked entirely normal.
  #
  # fallback is the shape the caller expects back, so nothing downstream has to
  # learn that translation can fail.
  def with_rates(fallback)
    yield
  rescue ExchangeRate::RateUnavailable => e
    note_missing_rate(e)
    fallback
  end

  # Run one of the Reports::*Totals calculators and record which series
  # answered. The calculator owns its own translators, so the controller does
  # not build any — it only asks, afterwards, what they used.
  #
  # What ANSWERED, not what the rules prefer. A report spanning several months
  # can legitimately show two — ESTV reaches back one month and the ECB covers
  # the rest — and more than one entry means the fallback fired, which is
  # exactly what a reader must be able to see.
  def run_totals(calculator)
    result = calculator.call
    @rate_sources = (@rate_sources.to_a | calculator.rate_sources)
    result
  end

  # Options for the converted-column dropdown, grouped so the currencies this
  # installation actually keeps books in sit apart from the rest — see
  # Reports::DisplayChoice.grouped_options.
  def currency_options
    Reports::DisplayChoice.grouped_options(
      @currencies,
      labels: { in_use: t("reports.currency_group.in_use"),
                others: t("reports.currency_group.others") },
      in_use: [ @display_currency, @effective_source ]
    )
  end

  # Which series this report reads, decided ONCE for its whole period, and the
  # only place tier 1's all-or-nothing rule is applied.
  #
  # A published series is used where it reaches every month; otherwise the whole
  # report cross-rates, and #effective_source is what the select then shows —
  # "CHF via ECB" rather than a column quietly built from two series.
  #
  # The currencies asked about are the ones the books USE, not the ones this
  # report happens to show: the report's own set is not known until after the
  # figures are computed, and a series covering all of them certainly covers a
  # subset.
  def resolve_display_source!(from, to)
    @effective_source = ExchangeRate.source_for_span(
      @display_currency,
      from_currencies: Currency.used_codes(scope: accessible_accounts),
      from: from.to_date, to: to.to_date,
      preferred: display_choice.source
    )
    @display_sources = [ @effective_source ].compact.presence

    # What the SELECT must show: the series the figures were actually built
    # from, which is not always the one that was asked for.
    #
    # NOT @display_param. That is what LINKS carry, and it stays bare when
    # nobody chose a series (Reports::DisplayChoice#to_param). Overwriting it
    # here put an invented source into every URL on the page.
    @display_selection = @effective_source ? "#{@display_currency}:#{@effective_source}"
                                           : display_choice.to_option
    @effective_source
  end

  def display_choice
    @display_choice ||= Reports::DisplayChoice.parse(
      params[:currency],
      available: report_currencies,
      fallback:  default_display_currency
    )
  end

  # Which published series produced the converted column, for the view. Never
  # re-derived from the rules or from the display currency — it is what
  # ANSWERED, which only the translators that did the work can say. The three
  # general reports fill it through #run_totals; a saved report gets it from
  # Reports::CustomReport, in the same data hash as the figures, so the screen
  # and the CSV cannot disagree.
  def rate_sources
    @rate_sources.to_a
  end

  # One place decides what a missing rate means: on screen the converted column
  # stays but comes out empty — it carries the currency-and-source select, and
  # removing it left no way to choose a different series — while the CSV
  # exporters drop it, because a file has no flash to explain itself. Either way
  # the user is told why, here.
  #
  # A flash rather than a bespoke notice, because that is how this app speaks.
  # shared/_flash marks the content html_safe, which is what lets the link
  # through; the content is entirely ours, no user input reaches it.
  def note_missing_rate(error)
    @rate_unavailable = error
    @rates_available  = false

    flash.now[:alert] = [
      t("reports.errors.no_rate",
        source: error.source.to_s.upcase,
        from:   error.from_currency,
        date:   I18n.l(error.date.to_date, format: :short_date)),
      t("reports.errors.no_rate_hint",
        from: error.from_currency, to: error.to_currency),
      helpers.link_to(t("reports.errors.no_rate_link"), exchange_rates_path)
    ].join(" ")
  end


  # Translated debit and credit with the FX variance folded into whichever side
  # it belongs to: a negative variance is missing debit, a positive one missing
  # credit. Returns nothing when there is no variance to fold.
  def adjusted_totals(totals, fx_variance)
    return {} if fx_variance.nil? || fx_variance.zero?

    {
      adjusted_debit:  totals[:translated_debit]  + (fx_variance.negative? ? fx_variance.abs : 0),
      adjusted_credit: totals[:translated_credit] + (fx_variance.positive? ? fx_variance : 0)
    }
  end

  

  def render_empty_profit_loss
    @income_accounts = []
    @expense_accounts = []
    @income_by_currency = {}
    @expense_by_currency = {}
    @currencies_with_data = []
    @currencies = report_currencies
    @currency_options = currency_options
    @available_entities = available_entity_codes
    @account_translated = {}
    @totals = {
      income_by_currency: Hash.new(0),
      expense_by_currency: Hash.new(0),
      net_by_currency: Hash.new(0),
      translated_income: 0,
      translated_expense: 0,
      translated_net: 0
    }
  end
  
end
