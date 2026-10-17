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
  # Date basis is entry_date, and there is nothing else: the app draws no
  # distinction between an invoice and a payment, so the tax point is whatever
  # date the bookkeeper put on the entry. A payment booked direct gives a cash
  # basis, an invoice booked against Creditors/Debtors an invoice basis. Neither
  # is privileged, and neither is detected.
  class VatReturn
    DEBITS  = "SUM(CASE WHEN postings.entry_type = 0 THEN postings.amount ELSE 0 END)"
    CREDITS = "SUM(CASE WHEN postings.entry_type = 1 THEN postings.amount ELSE 0 END)"

    Line = Struct.new(:code, :net, :tax, :reverse_tax, keyword_init: true)
    Box  = Struct.new(:key, :label, :reference, :amount, keyword_init: true)
    AccountLine = Struct.new(:account_code, :account_name, :code, :net, :tax,
                             keyword_init: true)

    def initialize(entity:, scheme:, from:, to:, flat_rate_bps: nil)
      @entity = entity
      @scheme = scheme
      @from   = from
      @to     = to
      # Basis points, from the REPORT. nil is an ordinary return, which is
      # almost every one.
      @flat_rate_bps = flat_rate_bps.to_i.positive? ? flat_rate_bps.to_i : nil
    end

    def call
      {
        entity:      @entity,
        scheme:      @scheme,
        scheme_label: TaxSchemeConfig.scheme_label(@scheme),
        # The authority's own words, not translated — the same rule as
        # no_tax_label. See TaxSchemeConfig's header notes.
        flat_rate_label:    TaxSchemeConfig.flat_rate_label(@scheme),
        normal_rules_label: TaxSchemeConfig.normal_rules_label(@scheme),
        currency:    TaxSchemeConfig.currency_for(@scheme),
        from:        @from,
        to:          @to,
        lines:       lines,
        # THE figures to file. Flat-rate adjusted when a rate is set, because
        # an MTD submission sends these nine numbers and nothing else — there
        # is no "I am on the flat rate scheme" flag for it to carry.
        boxes:       boxes,
        flat_rate_bps: @flat_rate_bps,
        # Never what a connector reads: the same period on the ordinary basis,
        # so the user can see whether the scheme is still worth being in.
        comparison_boxes: comparison_boxes,
        vat_due:     vat_due,
        vat_reclaimed: vat_reclaimed,
        net_payable: vat_due - vat_reclaimed,
        # Per account as well as per code. The by-code table reconciles the
        # boxes; this one is what an accountant can actually act on — a wrong
        # rate on electricity, or input tax that belongs to exempt income.
        account_lines: account_lines,
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
    def flat_rate? = !@flat_rate_bps.nil?

    def boxes
      @boxes ||= build_boxes(flat_rate? ? flat_rate_direct : standard_direct)
    end

    def comparison_boxes
      return [] unless flat_rate?
      @comparison_boxes ||= build_boxes(standard_direct)
    end

    # What every code puts into its own boxes. The ordinary basis.
    def standard_direct
      lines.each_with_object(Hash.new(0)) { |line, direct| add_line(direct, line) }
    end

    # Notice 733. Supplies outside the scheme keep normal treatment and are
    # "recorded in boxes 1 and 4 as you would under normal accounting".
    # Everything else contributes its VAT-INCLUSIVE value to the sales box, and
    # the tax box is the flat percentage of that — not the VAT actually charged.
    # Input tax inside the scheme is not reclaimed, so purchases contribute
    # their value and no tax.
    def flat_rate_direct
      direct   = Hash.new(0)
      turnover = 0

      lines.each do |line|
        next add_line(direct, line) if line.code.outside_flat_rate?

        # Sales build the flat-rate turnover. Purchases inside the scheme
        # contribute nothing at all — not even a value. Notice 700/12: box 7
        # is blank unless there is qualifying capital expenditure, something in
        # box 9, or a reverse charge, and those are all outside_flat_rate.
        turnover += line.net + line.tax if line.code.output?
      end

      if (sales_box = flat_rate_sales_box)
        direct[sales_box.first] += turnover
        direct[sales_box.last]  += Rational(turnover * @flat_rate_bps, 10_000).round(half: :up)
      end
      direct
    end

    def add_line(direct, line)
      direct[line.code.net_category_key] += line.net if line.code.net_category_key.present?
      direct[line.code.tax_category_key] += line.tax if line.code.tax_category_key.present?
      if line.code.reverse_tax_category_key.present?
        direct[line.code.reverse_tax_category_key] += line.reverse_tax
      end
    end

    # Which boxes the flat rate lands in, taken from an ordinary sale code
    # rather than hard-coded — so this is not silently GB-only.
    def flat_rate_sales_box
      code = codes.find { |c|
        c.output? && !c.outside_flat_rate? &&
          c.net_category_key.present? && c.tax_category_key.present?
      }
      code && [ code.net_category_key, code.tax_category_key ]
    end

    # There is deliberately no list of "things you should have excluded".
    # The app does not choose VAT rates for anyone either: the user picks the
    # code and the app records it. Listing three exclusions implies we check the
    # rest, which is worse than saying nothing — it manufactures confidence in
    # exactly the cases we are silent about. Removed 2026-10-16 on Daniela's
    # objection: "we should absolutely not give them ideas that we know all the
    # rules."

    def build_boxes(direct)
      # No early return on an empty period: a nil return is still a return, and
      # it is filed with nine zeros.

      categories = catalogue
      sums = roll_up(direct, categories)


      # EVERY box, including the empty ones. A VAT return has nine boxes and is
      # filed with nine figures — an MTD submission sends all of them — so a box
      # missing from the screen reads as a mistake rather than as a zero.
      # This used to hide zeros, which made box 7 silently absent under a flat
      # rate instead of visibly 0.00.
      sums.filter_map { |key, amount|
        category = categories[key]
        # A category with no box number is a FEEDER, not a box — it exists so
        # one code can reach two boxes (reverse_charge_services_net). A key with
        # no category at all is a catalogue error, and still shows, so it is
        # noticed rather than swallowed.
        next if category && category.reference.blank?
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

    # One row per account per code, because one expense account carries several
    # rates and the by-code total hides which account they came from. Three
    # queries, all grouped, nothing loaded.
    def account_lines
      @account_lines ||= begin
        nets  = signed_pairs(
          Posting.where(tax_code_id: codes.map(&:id)).where(account_id: entity_account_ids),
          [ :account_id, :tax_code_id ]
        )
        taxes   = tax_by_net_account
        by_code = codes.index_by(&:id)
        names   = Account.where(id: nets.keys.map(&:first).uniq)
                         .pluck(:id, :code, :name).to_h { |id, c, n| [ id, [ c, n ] ] }

        nets.filter_map { |(account_id, code_id), amount|
          code = by_code[code_id] or next
          # A sale credits income, a purchase debits expense; the table wants
          # both positive. Same rule as net_totals.
          net = code.output? ? -amount : amount
          tax = taxes[[ account_id, code_id ]].to_i
          next if net.zero? && tax.zero?

          account_code, account_name = names[account_id]
          AccountLine.new(account_code: account_code, account_name: account_name,
                          code: code, net: net, tax: tax)
        }.sort_by { |line| [ line.account_code.to_s, line.code.position, line.code.key.to_s ] }
      end
    end

    # The derived legs keyed by the account of the NET posting they came from.
    # Grouped by the control account's role as well, so a reverse charge — two
    # legs under one code — reports the code's own side rather than the two
    # cancelling to nothing.
    def tax_by_net_account
      @tax_by_net_account ||= begin
        rows = Posting.joins(:journal_entry, :account)
                      .joins("INNER JOIN postings net ON net.id = postings.tax_for_posting_id")
                      .where(journal_entries: { posted: true, entry_date: @from..@to })
                      .where(net: { tax_code_id: codes.map(&:id) })
                      .where(account_id: vat_account_ids)
                      .group(Arel.sql("net.account_id"), Arel.sql("net.tax_code_id"),
                             Arel.sql("accounts.vat_role"))
                      .pluck(Arel.sql("net.account_id"), Arel.sql("net.tax_code_id"),
                             Arel.sql("accounts.vat_role"),
                             Arel.sql(DEBITS), Arel.sql(CREDITS))

        directions = codes.to_h { |c| [ c.id, c.direction ] }
        rows.each_with_object({}) do |(account_id, code_id, role, debits, credits), out|
          role_name = role.is_a?(String) ? role : Account.vat_roles.key(role)
          next unless role_name == directions[code_id]
          out[[ account_id, code_id ]] =
            role_name == TaxCode::OUTPUT ? (credits - debits) : (debits - credits)
        end
      end
    end

    # Two grouping columns. signed_sums above takes one and is unchanged.
    def signed_pairs(scope, columns)
      scope.joins(:journal_entry)
           .where(journal_entries: { posted: true, entry_date: @from..@to })
           .group(*columns)
           .pluck(*columns, Arel.sql(DEBITS), Arel.sql(CREDITS))
           .each_with_object({}) { |(a, b, debits, credits), out| out[[ a, b ]] = debits - credits }
    end

    # By the SIDE the VAT landed on, not the code: a reverse charge owes and
    # reclaims under one code and both halves count.
    #
    # Under a flat rate these are NOT the VAT actually charged and paid — they
    # are what the return says is due, which is the whole point of the scheme.
    # Taken from the same figures the boxes are built from, so the summary and
    # the boxes cannot disagree.
    def vat_due
      @vat_due ||=
        if flat_rate?
          flat_rate_summary.first
        else
          tax_totals.sum { |(_, role), amount| role == TaxCode::OUTPUT ? amount : 0 }
        end
    end

    def vat_reclaimed
      @vat_reclaimed ||=
        if flat_rate?
          flat_rate_summary.last
        else
          tax_totals.sum { |(_, role), amount| role == TaxCode::INPUT ? amount : 0 }
        end
    end

    # Which categories mean "due" and which mean "reclaimed", read off the codes
    # rather than named, so this does not quietly become GB-only.
    def flat_rate_summary
      @flat_rate_summary ||= begin
        direct = flat_rate_direct
        due = (codes.select(&:output?).map(&:tax_category_key) +
               codes.select(&:input?).map(&:reverse_tax_category_key)).compact.uniq
        reclaimed = codes.select(&:input?).map(&:tax_category_key).compact.uniq
        [ due.sum { |k| direct[k] }, reclaimed.sum { |k| direct[k] } ]
      end
    end

    # The control accounts' movement less what the codes account for. Zero is
    # the normal answer.
    def unassigned
      # Under a flat rate the control accounts are SUPPOSED to diverge from the
      # boxes: you charge and pay VAT, and hand over a percentage of turnover
      # instead. Reporting that gap as something to go and fix was alarming and
      # wrong — the comparison column is where that difference belongs.
      return 0 if flat_rate?

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
