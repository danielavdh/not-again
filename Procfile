# Buildpack deploys only (Scalingo). Kamal/Docker ignore this file — they run
# the Dockerfile's CMD and .kamal/hooks/pre-deploy.
#
# jemalloc is set up by the Scalingo jemalloc-buildpack (see .buildpacks), which
# exports LD_PRELOAD itself — nothing to do here.
web: bundle exec puma -C config/puma.rb
release: bundle exec rails db:migrate && bundle exec rails tax_categories:load && bundle exec rails install:owner_if_missing
