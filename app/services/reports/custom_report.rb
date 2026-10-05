# frozen_string_literal: true

module Reports
  # A saved CUSTOM report: the bookkeeper's own curated list of accounts, any
  # type, grouped by parent account. The shared pipeline is in
  # Reports::Presenter; this supplies the account set, the rate policy and the
  # parent grouping.
  class CustomReport < Presenter
    private

    # The curated list, in the order set on the join rows.
    def ordered_accounts
      ids = report.account_ids_ordered
      return [] if ids.empty?

      by_id = Account.where(id: ids).includes(:parent).index_by(&:id)
      ids.filter_map { |id| by_id[id] }
    end

    # A saved report belongs to one report group → one entity, so that
    # business's elected rates apply. `scheme:` is nil for a custom group.
    def translation
      @translation ||= begin
        group = report.report_group
        Reports::Translation.new(
          display_currency: display_currency,
          sources:          @sources,
          scheme:           group&.tax_scheme,
          entity_id_for:    ->(_) { group&.entity&.id }
        )
      end
    end

    def empty_result
      { report: report, display_currency: display_currency, currencies: [], account_type_groups: [] }
    end

    def build(ordered_accounts)
      @all_parents = ordered_accounts.map(&:parent).compact.index_by(&:id)

      show_type_totals = types_contiguous?(ordered_accounts)
      parent_groups    = build_parent_groups_ordered(ordered_accounts)
      type_totals      = show_type_totals ? build_type_totals(ordered_accounts) : {}

      {
        report:           report,
        display_currency: display_currency,
        currencies:       @currencies,
        parent_groups:    parent_groups,
        type_totals:      type_totals,
        show_type_totals: show_type_totals,
        # The type the report ends on, so the closing total after the loop can
        # be printed without the template tracking where it got to.
        last_type:        parent_groups.last&.fetch(:account_type, nil),
        # Set when a rate was missing. The figures above are still right in
        # their own currencies; only the converted column is meaningless.
        rate_unavailable: rate_unavailable,
        # Which published series produced the converted column. Travels in the
        # data hash so the screen and the CSV cannot disagree about it.
        rate_sources:     rate_sources_used
      }
    end

    def types_contiguous?(ordered_accounts)
      seen = Set.new
      last_type = nil

      ordered_accounts.each do |account|
        type = account.account_type
        if type != last_type
          return false if seen.include?(type)
          seen.add(type)
          last_type = type
        end
      end

      true
    end

    def build_parent_groups_ordered(ordered_accounts)
      groups = []
      current_parent_id = nil
      current_children = []

      ordered_accounts.each do |account|
        parent_id = account.parent_id || account.id

        if parent_id != current_parent_id
          if current_children.any?
            group = finalize_parent_group(current_parent_id, current_children)
            groups << group if group
          end
          current_parent_id = parent_id
          current_children = [ account ]
        else
          current_children << account
        end
      end

      if current_children.any?
        group = finalize_parent_group(current_parent_id, current_children)
        groups << group if group
      end

      annotate_type_boundaries(groups)
    end

    # Where the account types change as you read down the report, so the
    # template does not have to track it. A group that opens a new type gets
    # :type_header, and :preceding_type_total to print that type's total first —
    # nil for the very first group.
    def annotate_type_boundaries(groups)
      last_type = nil
      groups.each do |group|
        next if group[:account_type] == last_type

        group[:preceding_type_total] = last_type
        group[:type_header]          = group[:account_type]
        last_type                    = group[:account_type]
      end
      groups
    end

    def finalize_parent_group(parent_id, accounts)
      account_data = accounts.filter_map { |a| account_row(a) }
      return nil if account_data.empty?

      parent = @all_parents[parent_id] || accounts.first
      parent_currency_totals = Hash.new(0)
      parent_translated_total = 0

      account_data.each do |ad|
        ad[:currency_totals].each { |curr, amt| parent_currency_totals[curr] += amt }
        parent_translated_total += ad[:translated_total]
      end

      return nil if parent_currency_totals.values.all?(&:zero?)

      parent_code = parent.respond_to?(:code) ? parent.code : accounts.first.code[0..3] + "00"
      parent_name = parent.respond_to?(:name) ? parent.name : "Unknown"

      {
        parent_id: parent_id,
        parent_code: parent_code,
        parent_name: parent_name,
        # A report is a chosen set of accounts, and each subtotal has its own
        # accounts listed directly above it — so the group is named after its
        # parent whether or not every child happens to be in the report. It used
        # to list the codes it covered instead whenever one was missing, which
        # said the same thing as the rows above it, in digits.
        total_name: "#{parent_code} - #{parent_name}",
        # Which of asset/liability/equity/income/expense this group belongs to.
        # Every account in a group shares a parent, so one answer.
        account_type: account_data.first[:account_type],
        accounts: account_data,
        currency_totals: parent_currency_totals,
        translated_total: parent_translated_total
      }
    end

    def build_type_totals(ordered_accounts)
      totals = {}

      ordered_accounts.group_by(&:account_type).each do |type, accounts|
        currency_totals = Hash.new(0)
        translated_total = 0

        accounts.each do |account|
          data = @postings_data[account.id]
          next unless data
          data[:by_currency].each { |curr, amt| currency_totals[curr] += amt }
          translated_total += data[:translated_total]
        end

        totals[type] = { currency_totals: currency_totals, translated_total: translated_total }
      end

      totals
    end
  end
end
