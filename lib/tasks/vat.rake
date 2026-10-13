# frozen_string_literal: true

namespace :vat do
  desc "Show what each account REMEMBERS for VAT and for the % split — the " \
       "last-used defaults the forms prefill from. Flags any a posting could " \
       "never actually use. Usage: bin/rails vat:defaults"
  task defaults: :environment do
    scope = Account.where.not(default_tax_code_id: nil)
                   .or(Account.where.not(deduction_percentage: nil))
                   .includes(:default_tax_code).order(:code)

    if scope.none?
      puts "No account remembers a VAT code or a split percentage."
      next
    end

    schemes_by_entity = Entity.pluck(:code, :tax_schemes).to_h
    problems = []

    puts format("%-8s %-30s %-10s %-26s %s", "CODE", "NAME", "TYPE", "VAT DEFAULT", "SPLIT")
    scope.each do |account|
      code = account.default_tax_code
      note = nil

      if code
        filed, = TaxSchemeConfig.vat_schemes(Array(schemes_by_entity[account.entity_code]))
        note = { not_nominal: "cannot carry VAT", direction: "wrong direction",
                 scheme: "scheme not filed" }[account.tax_code_problem(code, filed_schemes: filed)]
      end

      problems << [ account, note ] if note
      puts format("%-8s %-30s %-10s %-26s %s%s",
                  account.code, account.name.to_s[0, 30], account.account_type,
                  code ? "#{code.key} (#{code.direction})" : "—",
                  account.deduction_percentage ? "#{account.deduction_percentage}%" : "—",
                  note ? "   <-- #{note}" : "")
    end

    next if problems.empty?

    puts
    puts "#{problems.size} unusable VAT default(s). A posting would be refused, so the"
    puts "prefill only wastes a correction each time. Clear them with:"
    puts
    puts "  bin/rails vat:clear_unusable_defaults"
  end

  desc "Clear VAT defaults an account could never use on a posting. Does not " \
       "touch any books — these are form prefills only."
  task clear_unusable_defaults: :environment do
    schemes_by_entity = Entity.pluck(:code, :tax_schemes).to_h
    cleared = 0

    Account.where.not(default_tax_code_id: nil).includes(:default_tax_code).find_each do |account|
      code = account.default_tax_code
      filed, = TaxSchemeConfig.vat_schemes(Array(schemes_by_entity[account.entity_code]))
      next if account.tax_code_problem(code, filed_schemes: filed).nil?

      puts "  #{account.code} #{account.name}: dropping #{code.key}"
      account.update_column(:default_tax_code_id, nil)
      cleared += 1
    end

    puts cleared.zero? ? "Nothing to clear." : "Cleared #{cleared}."
  end
end
