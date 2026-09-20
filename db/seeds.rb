# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# The tax catalogues — reference data shipped with the code. Each file in
# db/tax_categories/ is a transcription of a real form (HMRC's SA103F, the German
# Anlage EÜR, and so on) and becomes one row per category in tax_categories.
# Without them the tax-category dropdowns are empty and nothing can be tagged, so
# a fresh clone needs them before it can do anything with tax at all.
#
# Loaded in exactly three places, none of them a user's request:
#   here (fresh install, db:reset), .kamal/hooks/pre-deploy (every deploy), and
#   bin/rails tax_categories:load by hand after editing a file.
#
# Idempotent: an upsert keyed on (country, scheme, year, key). It also DELETES
# rows a file no longer declares, which is why it is not something a user action
# should ever trigger — see README, "Tax catalogues".
Rake::Task["tax_categories:load"].invoke

# The four system languages — see Language and the migration that added
# `source`. Also inserted there via a migration-time `execute`, which is the
# real path for an environment that replays every migration in order — but
# `bin/setup`'s db:prepare, and any fresh install using db:schema:load
# (faster, and what this app's own deploy plan prefers), skip a migration's
# `execute` entirely and only load the schema. Found by running the actual
# test suite against the actual test database: the seeded rows were
# missing, silently, exactly the gap Currency's own comment already warns
# about for the same reason. find_or_create_by! makes this safe to run
# alongside that migration without double-inserting.
#
# ⚠️ Policy from 2026-09-14: a system language is only ever added once a
# human native speaker has actually reviewed it — reviewed is always true
# here, not a per-code exception. es/nl/ar are staying in this list only
# until Daniela finishes moving each to a reviewed custom row (which
# supersedes the system one — see Language#release!); once moved, its code
# comes out of this hash entirely rather than being left here unreviewed.
{
  "de" => "Deutsch",
  "es" => "Español",
  "nl" => "Nederlands"
}.each do |code, label|
  Language.find_or_create_by!(code: code, source: :system) do |language|
    language.label    = label
    language.status   = :released
    language.reviewed = true
  end
end
