# frozen_string_literal: true

# One live control account per entity, scheme and role — the rule
# Account#one_vat_account_per_scheme_and_role checks in Ruby, which two saves
# arriving together could both pass. The entity is digits 2 and 3 of the code.
# Partial, because a retired account may sit beside its live successor.
class AddUniqueIndexOnLiveVatAccounts < ActiveRecord::Migration[8.1]
  def change
    add_index :accounts, "tax_scheme, vat_role, substr(code, 2, 2)",
              unique: true,
              where:  "active AND vat_role IS NOT NULL",
              name:   "index_accounts_one_live_vat_account_per_role"
  end
end
