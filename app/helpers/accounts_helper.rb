# frozen_string_literal: true

module AccountsHelper
  # The currency picker on the account form: the FULL active list, because this
  # is one of only two places a currency arrives — but with the ones already in
  # use grouped to the front, since that is nearly always the answer.
  #
  # Grouped only when both groups have entries: an <optgroup> containing
  # everything is a heading that divides nothing. Returns option HTML rather
  # than a list, because the two shapes need different Rails helpers and the
  # template should not have to know that.
  def currency_options_for_account(selected)
    mine = Currency.used_codes(scope: accessible_accounts)
    used, rest = CurrencyConfig.available.partition { |c| mine.include?(c) }

    return options_for_select(CurrencyConfig.available, selected) if used.empty? || rest.empty?

    grouped_options_for_select(
      { t("reports.currency_group.in_use") => used,
        t("reports.currency_group.others") => rest },
      selected
    )
  end

  def debit_header_name(account_type)
    case account_type.to_s
    when 'asset' then 'Received'
    when 'liability' then 'Repaid'
    when 'equity' then 'Withdrawal'
    when 'income' then 'Refund'
    when 'expense' then 'Paid'
    when 'personal' then 'Paid'
    else 'Debit'
    end
  end

  def credit_header_name(account_type)
    case account_type.to_s
    when 'asset' then 'Spent'
    when 'liability' then 'Borrowed'
    when 'equity' then 'Contribution'
    when 'income' then 'Earned'
    when 'expense' then 'Refund'
    when 'personal' then 'Refund'
    else 'Credit'
    end
  end

  # Where "edit" goes for a line on a NOMINAL account's ledger. The entry was
  # made from the balance-sheet side, so editing it means opening the form it
  # was made in — the counter account's deposit or withdrawal form, or the
  # journal entry when it was neither. Nil when there is nothing to open, and
  # the ledger then shows no edit link at all.
  def ledger_edit_path(row)
    counter = row.counter_accounts.first
    je_id   = row.journal_entry_id

    case Posting.balance_account_edit_type(row.counter_accounts)
    when "deposit"       then edit_deposit_account_path(counter[1], journal_entry_id: je_id)
    when "withdrawal"    then edit_withdrawal_account_path(counter[1], journal_entry_id: je_id)
    when "journal_entry" then edit_journal_entry_path(je_id)
    end
  end

end