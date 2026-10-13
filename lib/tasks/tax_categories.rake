# this can still be used for assignment suggestions in terminal, but the actual
# assignment suggestions now are handled in dashboard controller, when setting
# up the tax categories. (choosing a country and which reports will be filed)

namespace :tax_categories do
  desc "Load tax category YAML files into tax_categories (idempotent upsert)"
  task load: :environment do
    dir = Rails.root.join('db', 'tax_categories')
    files = Dir.glob(dir.join('*.yml')).sort
    abort "No YAML files in #{dir}" if files.empty?

    categories = 0
    codes      = 0
    files.each do |path|
      result = TaxCategoryLoader.call(path)
      line = "  #{File.basename(path)}: #{result.categories} categories"
      line << ", #{result.codes} tax codes" if result.codes.positive?
      puts line
      categories += result.categories
      codes      += result.codes
    end
    puts "Loaded #{categories} categories and #{codes} tax codes from #{files.size} files."
  end

  desc "Preview tax category suggestions for an entity (never saves — confirm via dashboard)"
  task :auto_assign, [:entity_code] => :environment do |_t, args|
    entity_code = args[:entity_code] or abort "Usage: rake 'acc:tax_categories:auto_assign[AA]'"
    TaxCategoryAutoAssigner.call(entity_code: entity_code, dry_run: true)
  rescue ArgumentError => e
    abort e.message
  end
end