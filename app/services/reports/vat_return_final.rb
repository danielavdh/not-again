# frozen_string_literal: true

module Reports
  # Marking a VAT return final, and reopening it. The one place that does
  # either.
  #
  # Final means the return has been submitted to the authority. Three things
  # happen:
  #
  # 1. the return's CSV is kept as it is now (VatReturnStorage);
  # 2. the report is stamped, which locks the coded entries of its period
  #    (JournalEntry#final_vat_report);
  # 3. a clearing entry is booked on the period's last day. The VAT on purchases
  #    of the period moves onto VAT on sales, so VAT on sales holds what is owed
  #    to the authority and the two accounts stop growing side by side. On a
  #    flat-rate return the difference between the VAT the codes posted and the
  #    flat amount the return asks for goes to the scheme's flat-rate income
  #    account — a gain or, negative, a loss.
  #
  # Payments and refunds are not part of this: they are ordinary transfers to
  # and from VAT on sales.
  class VatReturnFinal
    def self.fingerprint(data)
      figures = [
        data[:boxes].map { |box| [ box.key.to_s, box.amount ] }.sort,
        data[:vat_due], data[:vat_reclaimed], data[:net_payable]
      ]
      Digest::SHA256.hexdigest(figures.to_json)[0, 12]
    end

    def initialize(report)
      @report = report
      @group  = report.report_group
    end

    # data is the return as computed for this request (Report#vat_return_data),
    # csv its file. Returns the clearing entry, or nil when there was nothing
    # to clear.
    def finalize!(data:, csv:)
      raise ArgumentError, "not a VAT return" unless @report.vat_report?
      return nil if @report.finalized?

      now = Time.current
      # First, and outside the transaction: a file cannot be rolled back. A
      # failure below leaves a file for a report that is not final, which the
      # next finalisation simply adds to.
      VatReturnStorage.upload(VatReturnStorage.key_for(@report.id, now, self.class.fingerprint(data)), csv)

      ApplicationRecord.transaction do
        @report.update!(finalized_at: now)
        book_clearing_entry(data)
      end
    end

    # Returns the clearing entry that was removed, or nil.
    def reopen!
      return nil unless @report.finalized?

      ApplicationRecord.transaction do
        entry = @report.vat_clearing_entry
        app_write { entry&.destroy! }
        @report.update!(finalized_at: nil)
        entry
      end
    end

    private

    def book_clearing_entry(data)
      # A scheme whose VAT accounts sit in the P&L has no balances to clear.
      return nil if TaxSchemeConfig.vat_accounts_nominal?(scheme)

      moved      = data[:posted_input]
      difference = if @report.flat_rate_bps
                     data[:posted_output] - data[:posted_input] - (data[:vat_due] - data[:vat_reclaimed])
                   else
                     0
                   end
      return nil if moved.zero? && difference.zero?

      entry = JournalEntry.new(
        entry_date: @report.end_date,
        memo:       I18n.t("reports.vat_final.clearing_memo", report: @report.name),
        vat_report: @report
      )
      add_line(entry, account(TaxCode::OUTPUT), moved + difference, :debit)
      add_line(entry, account(TaxCode::INPUT), moved, :credit)
      add_line(entry, account("flat_rate"), difference, :credit) unless difference.zero?

      app_write { entry.save! }
      entry
    end

    # A negative figure books on the other side.
    def add_line(entry, account, cents, side)
      return if cents.zero?
      side = (side == :debit ? :credit : :debit) if cents.negative?
      entry.postings.build(account: account, entry_type: side, amount: cents.abs)
    end

    def account(role)
      Account.resolve_vat_account(entity_code: @group.entity.code, scheme: scheme, direction: role)
    end

    def scheme = @group.tax_scheme

    def app_write
      Current.app_vat_clearing_write = true
      yield
    ensure
      Current.app_vat_clearing_write = false
    end
  end
end
