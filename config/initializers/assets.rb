Rails.application.config.assets.paths << Rails.root.join("app/assets/builds")

# Subresource integrity: the page carries each asset's hash, so a CDN serving an
# altered file has it refused by the browser.
Rails.application.config.assets.integrity_hash_algorithm = "sha384"
