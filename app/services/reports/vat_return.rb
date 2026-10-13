# frozen_string_literal: true

module Reports
  # One business, one scheme, one period: per code the net and the tax, mapped
  # through the code to the boxes of the authority's form.
  #
  # Neither a Reports::Presenter subclass nor LedgerBalances — both group
  # postings BY ACCOUNT, and a return groups them by CODE, because one expense
  # account carries several rates and several boxes. Three things the shared
  # pipeline does are not needed, which is why this is short rather than a copy:
  # no currency translation (a code may only be used on an entry in its scheme's
  # currency, so every figure is already in it), no date buckets, and no
  # debit-normal rule — a box's sign is the code's DIRECTION.
  #
  # Date basis is entry_date: the app records payments, so for a cash-basis
  # scheme that IS the tax point. Invoice-basis schemes are out of scope.
  class VatReturn
    DEBITS  = "SUM(CASE WHEN postings.entry_type = 0 THEN postings.amount ELSE 0 END)"
    CREDITS = "SUM(CASE WHEN postings.entry_type = 1 THEN postings.amount ELSE 0 END)"

    Line = Struct.new(:code, :net, :tax, :reverse_tax, keyword_init: true)
    Box  = Struct.new(:key, :label, :reference, :amount, keyword_init: true)

    def initialize(entity:, scheme:, from:, to:)
      @entity = entity
      @scheme = scheme
      @from   = from
      @to     = to
    end

    def call
      {
        entity:      @entity,
        scheme:      @scheme,
        scheme_label: TaxSchemeConfig.scheme_label(@scheme),
        currency:    TaxSchemeConfig.currency_for(@scheme),
        from:        @from,
        to:          @to,
        lines:       lines,
        boxes:       boxes,
        vat_due:     vat_due,
        vat_reclaimed: vat_reclaimed,
        net_payable: vat_due - vat_reclaimed,
        # VAT in the control accounts that no code put there: in the balance,
        # in no box, and nothing else would say so.
        unassigned:  unassigned
      }
    end

    private

    def codes
      @codes ||= TaxCode.for_schemes(@scheme).ordered.to_a
    end

    # Only codes that moved: a return listing every rate the country ever had at
    # 0.00 is harder to check than one listing what happened.
    def lines
      @lines ||= codes.filter_map { |code|
        net         = net_totals[code.id].to_i
        tax         = tax_totals[[ code.id, code.direction ]].to_i
        reverse_tax = code.reverse_charge? ? tax_totals[[ code.id, opposite(code.direction) ]].to_i : 0
        next if [ net, tax, reverse_tax ].all?(&:zero?)

        Line.new(code: code, net: net, tax: tax, reverse_tax: reverse_tax)
      }
    end

    # What the codes put directly into each box, plus the boxes it totals up.
    # Only boxes that end up with something: showing one at 0.00 that no code
    # can reach would say it had been checked.
    def boxes
      direct = Hash.new(0)
      lines.each do |line|
        direct[line.code.net_category_key] += line.net if line.code.net_category_key.present?
        direct[line.code.tax_category_key] += line.tax if line.code.tax_category_key.present?
        if line.code.reverse_tax_category_key.present?
          direct[line.code.reverse_tax_category_key] += line.reverse_tax
        end
      end
      return [] if direct.empty?

      categories = catalogue
      sums = roll_up(direct, categories)

      sums.filter_map { |key, amount|
        category = categories[key]
        next if amount.zero? && direct[key].zero?
        Box.new(key: key, label: category&.label || key.to_s.humanize,
                reference: category&.reference, amount: amount)
      }.sort_by { |box| [ categories[box.key]&.position || 9_999, box.key.to_s ] }
    end

    # The whole catalogue, not just the boxes codes name: a box that only TOTALS
    # others is fed by no code and would be missing from the lookup.
    def catalogue
      @catalogue ||= TaxCategory.catalogue_for(
        scheme: @scheme,
        year:   TaxCategory.tax_year_for(
                  country_code: TaxSchemeConfig.country_for(@scheme), date: @to
                )
      )
    end

    # Adds each box's included boxes into it, to any depth: HMRC's box 6 includes
    # the dispatches in box 8, so a figure is reported twice on purpose. The
    # `seen` guard is because the catalogue is written by hand.
    def roll_up(direct, categories)
      resolved = {}

      total_for = lambda { |key, seen|
        return resolved[key] if resolved.key?(key)
        return direct[key].to_i if seen.include?(key)

        children = categories[key]&.includes || []
        amount = direct[key].to_i + children.sum { |child| total_for.call(child, seen + [ key ]) }
        resolved[key] = amount
      }

      (direct.keys | categories.keys).each_with_object({}) do |key, out|
        out[key] = total_for.call(key, [])
      end
    end

    # By the SIDE the VAT landed on, not the code: a reverse charge owes and
    # reclaims under one code and both halves count.
    def vat_due
      @vat_due ||= tax_totals.sum { |(_, role), amount| role == TaxCode::OUTPUT ? amount : 0 }
    end

    def vat_reclaimed
      @vat_reclaimed ||= tax_totals.sum { |(_, role), amount| role == TaxCode::INPUT ? amount : 0 }
    end

    # The control accounts' movement less what the codes account for. Zero is
    # the normal answer.
    def unassigned
      ids = Account.vat_accounts.for_entity_codes([ @entity.code ])
                   .where(tax_scheme: @scheme).pluck(:id)
      return 0 if ids.empty?

      moved = signed_sums(Posting.where(account_id: ids), group: :account_id)
      # Owed sits on the credit side and reclaimable on the debit side, so
      # credits less debits IS the net payable. signed_sums gives the reverse.
      from_accounts = -moved.values.sum
      from_accounts - (vat_due - vat_reclaimed)
    end

    # One query.
    def net_totals
      @net_totals ||= signed_sums(
        Posting.where(tax_code_id: codes.map(&:id)).where(account_id: entity_account_ids),
        group: :tax_code_id
      ).each_with_object({}) { |(code_id, amount), out|
        # A sale CREDITS income, a purchase DEBITS expense, and a return wants
        # both as positive figures. amount here is debits less credits, so the
        # sale's sign flips and the purchase's does not.
        out[code_id] = direction_of(code_id) == TaxCode::OUTPUT ? -amount : amount
      }
    end

    # The derived legs, by (code, the role of the account they landed on). One
    # query. Keyed by the ROLE rather than by the code's direction, because a
    # reverse charge produces one leg of each.
    def tax_totals
      @tax_totals ||= begin
        rows = Posting.joins(:journal_entry, :account)
                      .joins("INNER JOIN postings net ON net.id = postings.tax_for_posting_id")
                      .where(journal_entries: { posted: true, entry_date: @from..@to })
                      .where(net: { tax_code_id: codes.map(&:id) })
                      .where(account_id: vat_account_ids)
                      .group(Arel.sql("net.tax_code_id"), Arel.sql("accounts.vat_role"))
                      .pluck(Arel.sql("net.tax_code_id"), Arel.sql("accounts.vat_role"),
                             Arel.sql(DEBITS), Arel.sql(CREDITS))

        rows.each_with_object({}) do |(code_id, role, debits, credits), out|
          # A joined enum column comes back raw: Rails does not cast across a join.
          role_name = role.is_a?(String) ? role : Account.vat_roles.key(role)
          out[[ code_id, role_name ]] =
            role_name == TaxCode::OUTPUT ? (credits - debits) : (debits - credits)
        end
      end
    end

    # Debits less credits, posted entries only. Callers apply the authority's
    # sign.
    def signed_sums(scope, group:)
      scope.joins(:journal_entry)
           .where(journal_entries: { posted: true, entry_date: @from..@to })
           .group(group)
           .pluck(group, Arel.sql(DEBITS), Arel.sql(CREDITS))
           .each_with_object({}) { |(key, debits, credits), out| out[key] = debits - credits }
    end

    def entity_account_ids
      @entity_account_ids ||= Account.for_entity_codes([ @entity.code ]).select(:id)
    end

    def vat_account_ids
      @vat_account_ids ||= Account.vat_accounts.for_entity_codes([ @entity.code ])
                                  .where(tax_scheme: @scheme).select(:id)
    end

    def direction_of(code_id)
      @directions ||= codes.to_h { |c| [ c.id, c.direction ] }
      @directions[code_id]
    end

    def opposite(direction)
      direction == TaxCode::INPUT ? TaxCode::OUTPUT : TaxCode::INPUT
    end
  end
end
