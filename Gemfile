source 'https://rubygems.org'
ruby "3.4.7"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
gem 'dartsass-rails' # needs to be set up with importmaps
# Use postgresql as the database for Active Record
# Compile pg from source: the precompiled fat gem bundles its own libpq, which
# segfaults on connect on macOS. Built against Postgres.app locally (build.pg
# config) and libpq-dev in the Docker build.
gem "pg", "~> 1.6", force_ruby_platform: true
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 7.0.3"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Rails' own strings (dates, numbers, errors, currency formats) for every
# locale — https://github.com/svenfuchs/rails-i18n. Replaces the handful of
# files that used to be copied into config/locales/ by hand: adding a language
# is now one initializer line + one app-strings file, nothing downloaded. The
# number-format picker (NumberFormat) also reads its per-locale currency
# formats from here.
gem "rails-i18n", "~> 8.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
#gem "jbuilder"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

gem "shrine", "~> 3.9"
gem "image_processing", "~> 2.1", require: false
gem "fastimage" 
# ⚠️ require: "zip", not the default guess — the gem is named rubyzip but its
# own file is lib/zip.rb, so Bundler's naive `require "rubyzip"` silently
# fails to find anything and just moves on, no error, Zip never defined. Only
# looked loaded in test because selenium-webdriver (test-only) requires "zip"
# itself as a side effect — development and production never had it.
gem 'rubyzip', require: "zip"
gem "aws-sdk-s3", "~> 1.232", require: false
gem 'rack-cors', require: 'rack/cors'
gem "rack-attack"

gem 'csv'
gem 'pagy', '~> 43.6'                      
gem 'RedCloth'
gem "recaptcha", require: 'recaptcha/rails' 
# Two-factor authentication
gem "rotp", "~> 6.3"
gem "rqrcode", "~> 2.2"


# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache and Active Job
#gem "solid_cache"
gem "solid_queue"
gem "mission_control-jobs"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
  
  gem "foreman", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
  # Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
  gem "kamal", require: false

#  gem "editor_and_preview", '1.0.1', path: "~/Sites/GEMS/editor_and_preview"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # Held at 5 deliberately. Nothing asks for minitest by name, so a routine
  # `bundle update rails` resolved it to 6, which drops `minitest/mock` —
  # test_helper requires it, and the whole suite failed to load. Moving to 6 is
  # its own job: extract the mock dependency first, then lift this pin.
  gem "minitest", "~> 5.26"
end
