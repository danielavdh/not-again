# frozen_string_literal: true

# The currencies this installation supports. Adding one can leave a currency
# nothing publishes a rate for, so the coverage probe runs on create.
class CurrenciesController < BaseController
  before_action :ensure_full_access
  before_action :set_currency, only: [ :edit, :update, :destroy, :deactivate, :reactivate ]

  def index
    @currencies = Currency.in_display_order

    # Which sources we hold rates from — also the honest answer to "who
    # publishes this", since the nightly fetch stores every supported currency a
    # feed returns.
    #
    # Empty means one of two things and the label must not pretend otherwise:
    # nobody publishes it, or it was added before the last fetch ran.
    @held = Rates::CoverageProbe.stored_coverage
    @fetched_since = @currencies.index_with { |c| c.created_at < last_fetch_at }
  end

  def new
    @currency = Currency.new
  end

  def create
    @currency = Currency.new(currency_params)

    if @currency.save
      # Asking the feeds takes four HTTP requests, which has no business inside
      # a form submission. The answer arrives by email.
      CurrencyCoverageJob.perform_later(code: @currency.code,
                                             admin_id: current_admin.id,
                                             locale: I18n.locale.to_s)
      redirect_to currencies_path,
                  notice: t("currencies.created", code: @currency.code)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  # Stripped here, not merely hidden on the form: a disabled field is a
  # suggestion, a crafted request is not. See Currency#settled?.
  def update
    attrs = currency_params
    attrs = attrs.except(:code, :symbol) if @currency.settled? && !sudo?

    if @currency.update(attrs)
      redirect_to currencies_path, notice: t("currencies.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::StaleObjectError
    @currency = @currency.reload
    flash.now[:alert] = t("currencies.stale")
    render :edit, status: :conflict
  end

  # Retiring a currency is sudo's alone. It is the field with the widest blast
  # radius — it also stops rates being fetched, via CurrencyConfig.available
  # (Rates::Fetcher#store_rates).
  #
  # The one thing refused outright, with no override even for sudo: activity in
  # the last two months (#recently_active?), because a report not yet finished
  # may still need the currency selectable.
  def deactivate
    return refuse_retirement unless sudo?

    if @currency.recently_active?
      return redirect_to currencies_path,
                         alert: t("currencies.recently_active", code: @currency.code)
    end

    @currency.update(active: false)
    redirect_to currencies_path,
                notice: t("currencies.deactivated", code: @currency.code)
  end

  def reactivate
    return refuse_retirement unless sudo?

    @currency.update(active: true)
    redirect_to currencies_path,
                notice: t("currencies.reactivated", code: @currency.code)
  end

  # Delete is for a currency nothing rests on, and never falls back to
  # deactivating: deleting an unused row is housekeeping, retiring a live one is
  # sudo's.
  def destroy
    if @currency.in_use?
      redirect_to currencies_path,
                  alert: t("currencies.in_use", code: @currency.code)
    else
      @currency.destroy
      redirect_to currencies_path, notice: t("currencies.deleted")
    end
  end

  private

  def refuse_retirement
    redirect_to currencies_path, alert: t("currencies.sudo_only")
  end

  def set_currency
    @currency = Currency.find(params[:id])
  end

  # A currency added since the last write has simply not had its turn yet — a
  # different thing from nobody publishing it, and the only way to tell the two
  # apart without asking the feeds again.
  def last_fetch_at
    @last_fetch_at ||= ExchangeRate.maximum(:updated_at) || Time.current
  end

  def currency_params
    # Not :active — retiring is a named action, never a submittable attribute.
    # Not :position either: display order is a rule, not a field.
    params.require(:currency).permit(:code, :symbol, :lock_version)
  end
end
