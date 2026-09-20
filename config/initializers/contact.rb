# Provider identity and public contact address: shown on the legal pages (Who-
# we-are and Impressum, in all four languages) and in /.well-known/security.txt.
#
# Read from the environment, because this repo is public and every installation
# has a different operator. Set them in config/deploy.yml, or for a real
# deployment in the gitignored config/deploy.<destination>.yml.
#
# Production REFUSES TO BOOT with these unset: in Germany an Impressum is a
# legal requirement (§5 DDG), and a legal page with holes in it is worse than a
# deployment that stops and tells you why. Development and test fall back to
# obvious placeholders, and so does the image build.
required = Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].nil?

contact = lambda do |name, example|
  ENV[name].presence || begin
    raise "#{name} is not set. It appears on the legal pages and in security.txt — " \
          "see the env block in config/deploy.yml." if required
    example
  end
end

# A DISPOSABLE ALIAS forwarding into the real mailbox — never the real mailbox
# itself. If it drowns in spam, make a fresh alias, change the env var,
# redeploy: every published spot follows from here.
SERVICE_NAME    = contact.call("SERVICE_NAME",    "Your Bookkeeping Service")

CONTACT_EMAIL   = contact.call("CONTACT_EMAIL",   "you@example.com")

CONTACT_NAME    = contact.call("CONTACT_NAME",    "Your Name")
CONTACT_TRADING = contact.call("CONTACT_TRADING", "Your Trading Name")
CONTACT_STREET  = contact.call("CONTACT_STREET",  "1 Example Street")
CONTACT_CITY    = contact.call("CONTACT_CITY",    "00000 Example City")
CONTACT_COUNTRY = contact.call("CONTACT_COUNTRY", "Country")

# The public repository. Optional: the landing page shows its GitHub links only
# when this is set, so an unset or forked installation never links to the wrong
# place.
REPO_URL = ENV["REPO_URL"].presence

# The From: address on every email this installation sends. Must be a sender the
# mail provider has authorised — normally no-reply@<your domain>, which is what
# this derives from APP_HOST. Override MAIL_FROM only if the authorised address
# differs.
derived_host = Rails.application.config.action_mailer.default_url_options&.dig(:host)
derived_from = derived_host ? "no-reply@#{derived_host.sub(/\Awww\./, '')}" : "no-reply@localhost"
MAIL_FROM = ENV["MAIL_FROM"].presence || 
            Rails.application.credentials.dig(:smtp, :from).presence ||
            derived_from
