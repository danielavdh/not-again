# frozen_string_literal: true

# Resolves bracket placeholders in admin-authored language content — legal text,
# terms — back to this installation's real contact details.
#
# Why placeholders exist: a translation round-trip goes through an AI, which
# does not reliably know that "smith@example.com" is fixed data rather than more
# prose to render into Bulgarian. A bracketed token like [EMAIL] reads
# unambiguously as "do not translate this" to both a person and an AI. So the
# downloadable template carries tokens, never the real values, and this is what
# puts the real values back at render time.
#
# Deliberately NOT duplicated per language: every released language reads
# through here, so there is exactly one place to change if the source of these
# values ever changes.
module ContactPlaceholders
  # token => the constant it resolves to (config/initializers/contact.rb). A
  # Hash of blocks, not of resolved values, to keep this file honest about being
  # a LOOKUP rather than a second copy.
  #
  # If a future admin screen ever lets sudo hold several sets of these details
  # and choose between them per language — the reason this is its own small
  # module rather than inline wherever content is rendered — that changes
  # exactly this one method, not every call site.
  TOKENS = {
    "[EMAIL]"        => -> { CONTACT_EMAIL },
    "[SERVICE NAME]" => -> { SERVICE_NAME },
    "[TRADING NAME]" => -> { CONTACT_TRADING },
    "[LEGAL NAME]"   => -> { CONTACT_NAME },
    "[STREET]"       => -> { CONTACT_STREET },
    "[CITY]"         => -> { CONTACT_CITY },
    "[COUNTRY]"      => -> { CONTACT_COUNTRY },
    # Not a CONTACT_* constant: service_host also falls back to request.host,
    # which this module cannot reach outside a request. APP_HOST is set in
    # production, so this is only an approximation in the rare case it is not.
    "[WEBSITE]"      => -> { ENV["APP_HOST"].presence || "localhost" }
  }.freeze

  def self.fill(text)
    return text if text.blank?

    TOKENS.reduce(text) { |result, (token, value)| result.gsub(token, value.call) }
  end
end
