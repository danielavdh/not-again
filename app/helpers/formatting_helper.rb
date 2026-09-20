# frozen_string_literal: true

module FormattingHelper
  # Primary formatting method - delegates to CurrencyConfig
  def format_amount(cents, currency = nil)
    CurrencyConfig.format_cents(cents, currency, locale: I18n.locale)
  end
  # Alias for views that use format_cents
  def format_cents(cents, currency = nil)
    return '' if cents.nil? || cents == 0
    format_amount(cents, currency)
  end

  def format_cents_with_currency(cents, currency, invert: false, show_zero: false)
    return '' if cents.nil?
    return '' if cents == 0 && !show_zero
    display_cents = invert ? -cents : cents
    CurrencyConfig.format_cents(display_cents, currency, locale: I18n.locale)
  end

  # For CSV export
  def format_amount_csv(cents)
    CurrencyConfig.format_cents_csv(cents)
  end

  # available_currencies lives on BaseController as a helper_method and is
  # deliberately not repeated here.

  # Format with negative handling (parentheses + red)
  def format_amount_signed(cents, currency = nil)
    return '' if cents.nil?
    CurrencyConfig.format_cents(cents, currency, locale: I18n.locale)
  end

  # Badges and date formatting (unchanged)
  def posting_type_badge(entry_type)
    color = entry_type == 'debit' ? 'text-success' : 'text-danger'
    content_tag(:span, entry_type.upcase, class: color)
  end

  def account_type_badge(account_type)
    content_tag(:span, t("jargon.#{account_type}"), class: "badge badge-#{account_type}")
  end

  def format_date(date)
    return '' unless date
    I18n.l(date, format: :short_date)
  end

  # Transaction type helpers (unchanged)
  def transaction_type_from_counter_accounts(counter_accounts)
    return 'Unknown' if counter_accounts.empty?
    return 'Split' if counter_accounts.size > 1

    account_type = counter_accounts.first[4]
    case account_type
    when 5, 'expense' then 'Expense'
    when 4, 'income' then 'Income'
    when 0, 1, 2, 'asset', 'liability', 'equity' then 'Transfer'
    when 6, 'personal' then 'Personal'
    else 'Other'
    end
  end

  def format_counter_account_text(counter_accounts)
    return '' if counter_accounts.empty?
    if counter_accounts.size == 1
      "#{counter_accounts.first[2]} - #{counter_accounts.first[3]}"
    else
      "Split (#{counter_accounts.size})"
    end
  end

end