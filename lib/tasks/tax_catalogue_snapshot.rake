# frozen_string_literal: true

namespace :tax_categories do
  desc "Rewrite the catalogue snapshot the guard test compares against (only when a change is deliberate)"
  task snapshot: :environment do
    path = TaxCatalogueSnapshot::PATH
    TaxCatalogueSnapshot.write!
    puts "Wrote #{path.relative_path_from(Rails.root)}"
    puts "Commit it in the SAME commit as the catalogue change, so the diff shows what moved and why."
  end
end
