class ExchangeRatesController < BaseController
  # Writing rates by hand is governed by Rates::WritePolicy; fetching is not.
  before_action :set_exchange_rate, only: [:show, :edit, :update, :destroy]
  # An entity's own rate — and its evidence note — is only for an admin linked
  # to that entity. update/destroy check too, but only after the form has
  # already been served, so the guard has to run here.
  before_action :ensure_rate_visible, only: [:show, :edit, :update, :destroy]
  # Built from db/exchange_rate_sources.yml, so a new source appears in both
  # dropdowns without anyone editing a template.
  before_action :set_source_options
  def index
    @pagy, @exchange_rates = pagy(
      visible_rates.order(effective_date: :desc, from_currency: :asc),
      limit: 25,
      paginator: :countish
    )
    # Which rows this admin may act on. Two queries for the page rather than two
    # per row — see Rates::WritePolicy.writable_map, which exists because asking
    # per row measured 50 queries for 25 rates.
    @writable_rates = Rates::WritePolicy.writable_map(@exchange_rates, current_admin)

    respond_to do |format|
      format.html
      format.csv { export_csv }
    end
  end

  def show; end

  def new
    # Defaults to the current whole month, which is what almost every rate is.
    # A daily rate is then one field to change, not two to work out.
    @exchange_rate = ExchangeRate.new(
      valid_from: Date.current.beginning_of_month,
      valid_to:   Date.current.end_of_month
    )
  end

  # A typed rate is NEVER global. Leaving the entity blank means "all of my
  # entities" and writes one row each — a convenience so an admin with four
  # businesses need not type the same figure four times, not a shared row by
  # another name.
  #
  # All-or-nothing: four rows from one submission are one act, and half of them
  # landing would be worse than none.
  def create
    targets = target_entity_ids
    if targets.empty?
      @exchange_rate = ExchangeRate.new(exchange_rate_params)
      return refuse(@exchange_rate, :new)
    end

    rates = targets.map { |entity_id| build_typed_rate(entity_id) }
    @exchange_rate = rates.first

    refusal = rates.find { |r| !writable?(r) }
    return refuse(refusal, :new) if refusal

    saved = ExchangeRate.transaction do
      rates.all?(&:save) || raise(ActiveRecord::Rollback)
    end

    if saved
      redirect_to exchange_rates_path,
                  notice: t("exchange_rates.created_count", count: rates.size,
                                                            rate: @exchange_rate.rate_sentence)
    else
      @exchange_rate = rates.find { |r| r.errors.any? } || rates.first
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    # Checked before and after assigning: before, so an admin cannot edit a rate
    # they may not touch; after, so they cannot move one they may touch into a
    # period or an entity they may not.
    return refuse(@exchange_rate, :edit) unless writable?(@exchange_rate)

    # An edit leaves the row's IDENTITY alone — its source, and whether it is
    # shared or an entity's own. Only the figures change.
    #
    # Forcing source: manual here turns sudo's correction of a fetched ECB row
    # into a global manual row. It matters most for ESTV, whose past months can
    # never be re-fetched, so "delete and pull it again" is not available there.
    was_global = @exchange_rate.entity_id.nil?
    source     = @exchange_rate.source

    @exchange_rate.assign_attributes(exchange_rate_params)
    @exchange_rate.source = source
    @exchange_rate.entity_id = nil if was_global
    # Who touched it is still worth recording, even on a fetched row.
    @exchange_rate.entered_by = current_admin

    return refuse(@exchange_rate, :edit) unless writable?(@exchange_rate)

    if @exchange_rate.save
      redirect_to exchange_rates_path,
                  notice: t("exchange_rates.updated", rate: @exchange_rate.rate_sentence)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    return refuse(@exchange_rate, nil) unless writable?(@exchange_rate)

    @exchange_rate.destroy
    redirect_to exchange_rates_path, notice: t("exchange_rates.deleted")
  end
  
  def fetch_rates
    source = params[:source]
    month_str = params[:month]
    unless RateSourceConfig.exists?(source) && month_str.match?(/\A\d{4}-\d{2}\z/)
      return redirect_to exchange_rates_path, alert: "Invalid source or month."
    end

    month_start = Date.parse("#{month_str}-01")
    date = RateSourceConfig.fetch_date_for(source, month_start)

    # Whether a period exists yet is the SOURCE's question, not the controller's
    # — CurrencyCoverageJob needs the same answer, and a second copy of a three-
    # branch rule is how the first one drifts.
    not_yet = !RateSourceConfig.period_available?(source, month_start)
    if not_yet
      label = RateSourceConfig.label_for(source)
      return redirect_to exchange_rates_path,
                         alert: "#{label} rates for #{month_str} are not yet available."
    end

    # No "already exists" refusal. Skipping when any rate for that source and
    # month is present would block a publisher's correction, and would block a
    # newly supported currency for a month that already holds the others — the
    # case you most want the button for.
    #
    # The fetcher upserts on (pair, span, source), so re-fetching updates in
    # place.
    result = Rates::Fetcher.fetch_and_store(source, date)
    label  = RateSourceConfig.label_for(source)

    if result[:not_published]
      redirect_to exchange_rates_path,
                  alert: "#{label} has not published rates for #{month_str} yet."
    elsif result[:success]
      # Report the period actually STORED, not the one asked for. ESTV's feed
      # serves the current month only and ignores ?d=, ?month= and ?date=, so
      # asking it for July returns August — correctly stored under August's
      # span, because the parser trusts the feed. Any feed that quietly ignores
      # a date request announces it here rather than echoing back the month
      # requested.
      stored = result[:valid_from]
      got    = stored&.strftime("%Y-%m")

      if got && got != month_str
        redirect_to exchange_rates_path,
                    alert: "#{label} does not serve past months: you asked for #{month_str} " \
                           "and it returned #{got}. #{result[:count]} rates stored for #{got}."
      else
        redirect_to exchange_rates_path,
                    notice: "#{result[:count]} rates stored or updated for #{got || month_str} (#{label})."
      end
    else
      redirect_to exchange_rates_path, alert: "Fetch failed: #{result[:error]}"
    end
  end

  def lookup
    from = params[:from]
    to   = params[:to]

    unless from.in?(available_currencies) && to.in?(available_currencies)
      return render json: { error: "Invalid currency" }, status: :unprocessable_entity
    end

    date = Date.parse(params[:date]) rescue Date.current

    source = ExchangeRate.source_for(to)
    rate = ExchangeRate.rate_for(from, to, date: date, source: source)

    render json: { rate: rate&.round(6), source: source }
  end

  private

  # One entity if the form named it, otherwise every entity the admin may write
  # — never none, because a typed rate is never global.
  def target_entity_ids
    chosen = exchange_rate_params[:entity_id].presence
    return [ chosen.to_i ] if chosen

    Entity.where(code: current_admin&.writable_entity_codes.to_a).pluck(:id)
  end

  # source is always manual and entered_by is always the current admin — both
  # stamped, never submitted.
  #
  # A typed rate is nobody's publication: filing one as ecb would put a private
  # figure into the series everyone reads, and make the ECB look as though it
  # published a currency it does not. Where the figure IS a publisher's, that
  # belongs in the evidence note.
  def build_typed_rate(entity_id)
    ExchangeRate.new(exchange_rate_params).tap do |rate|
      rate.entity_id = entity_id
      rate.source        = "manual"
      rate.entered_by    = current_admin
    end
  end

  def writable?(rate)
    Rates::WritePolicy.writable?(rate, current_admin)
  end

  # Refusing with a REASON, because the two need different actions from the
  # person reading them: "another entity's rate" is final, "this period can be
  # fetched" is an instruction to press Fetch — and a warning that typing it
  # would be overwritten anyway.
  def refuse(rate, template)
    message = case Rates::WritePolicy.refusal_reason(rate, current_admin)
    when :no_entity_access
      t("exchange_rates.errors.not_your_entity")
    else
      # :shared_series — a global row is what a publisher published, and only
      # sudo may change it.
      t("exchange_rates.errors.shared_series",
        label: RateSourceConfig.label_for(rate.source))
    end

    if template
      flash.now[:alert] = message
      render template, status: :forbidden
    else
      redirect_to exchange_rates_path, alert: message
    end
  end

  def set_source_options
    # Only the fetch control needs a source list; the rate form has none, since
    # a typed rate is always manual.
    #
    # Named by the AUTHORITY that accepts each feed rather than by the publisher
    # — an admin knows who their tax boss is and may not know which central bank
    # that authority points at. Several options can share one source key; they
    # all fetch the same thing once. See Rates::FetchOptions.
    @fetchable_sources = Rates::FetchOptions.call

    # Only entities this admin may write. Offering one they cannot would let
    # them build a form the policy then refuses, which is worse than not
    # offering it. Sudo sees all of them.
    codes = current_admin&.sudo? ? nil : current_admin&.writable_entity_codes
    scope = codes ? Entity.where(code: codes) : Entity.all
    @entity_options = scope.order(:code).pluck(:name, :id)
                           .map { |name, id| [ name, id ] }
  end

  def set_exchange_rate
    @exchange_rate = ExchangeRate.find(params[:id])
  end

  # The shared series plus this admin's own entities' rates. Sudo sees all.
  def visible_rates
    return ExchangeRate.all if current_admin&.sudo?

    ExchangeRate.where(entity_id: [ nil, *current_admin&.accessible_entity_ids ])
  end

  def ensure_rate_visible
    return if Rates::WritePolicy.visible?(@exchange_rate, current_admin)

    redirect_to exchange_rates_path, alert: t("access.read_only_deny")
  end

  # entered_by_id is deliberately NOT permitted — it is stamped from the
  # session, or the audit trail would be whatever the form said it was.
  #
  # source is NOT permitted either: a rate's publisher is not a user's to
  # assert. create stamps manual, update leaves whatever was there; without this
  # a crafted request could file a typed figure as an ECB one.
  #
  # effective_date is NOT permitted: the form asks for a span, and the model
  # fills the column from valid_from while it still exists.
  def exchange_rate_params
    params.require(:exchange_rate)
          .permit(:from_currency, :to_currency, :rate,
                  :valid_from, :valid_to, :note, :entity_id)
  end

  def export_csv
    data = visible_rates.order(effective_date: :desc, from_currency: :asc)
      .pluck(:effective_date, :from_currency, :to_currency, :rate, :source)

    stream_csv_from_array(
      filename: "exchange_rates_#{Date.current}.csv",
      headers: %w[Date From To Rate Source],
      data: data
    )
  end
end
