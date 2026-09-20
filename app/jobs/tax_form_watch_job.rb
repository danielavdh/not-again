# frozen_string_literal: true

require "net/http"
require "digest"

# Watches the forms the tax catalogues were built from.
#
# The catalogues in db/tax_categories are transcriptions of real documents —
# SA103F, SA105, Anlage EÜR, Anlage V — and authorities reissue those without
# telling anyone. A wrong box number does not raise; it files a figure in the
# wrong place. This job is the only thing that would notice.
#
# Silent unless something differs. Three findings are worth an email:
#
# :changed     the file at that URL is no longer the one we transcribed
# :newer_year  a later edition is listed on the authority's own page
# :gone        the URL returns 404/410 — the address moved, or the form was
# withdrawn. Distinct from being unable to reach the network at all, which is
# not news and is only logged.
#
# Switzerland declares no source: OR Art. 959b is statute, not a form.
class TaxFormWatchJob < ApplicationJob
  queue_as :default

  # How far ahead to look for a new edition. Bounded on purpose — scanning a
  # page for "the highest four-digit number" would happily latch onto a
  # reference number or a phone extension and report the year 4015.
  LOOKAHEAD_YEARS = 5

  def perform
    findings = TaxSchemeConfig.all_schemes.filter_map { |scheme| check(scheme) }
    return if findings.empty?

    AdminMailer.with(findings: findings).tax_forms_changed.deliver_now
  end

  private

  def check(scheme)
    source = TaxSchemeConfig.source_for(scheme)
    return nil if source.blank?

    finding = check_file(scheme, source) || check_for_newer_edition(scheme, source)
    Rails.logger.info("TaxFormWatchJob: #{scheme} — #{finding ? finding[:kind] : 'unchanged'}")
    finding
  end

  # Has the document we transcribed been replaced at its own address?
  def check_file(scheme, source)
    url    = source["url"].presence
    expect = source["sha256"].presence
    return nil unless url && expect

    body, status = fetch(url)

    case status
    when :ok
      actual = Digest::SHA256.hexdigest(body)
      return nil if actual == expect
      finding(scheme, :changed, source,
              "The file at this address is no longer the one the catalogue was built from.",
              "expected #{expect[0, 12]}…, found #{actual[0, 12]}…")
    when :gone
      finding(scheme, :gone, source,
              "The address no longer resolves to a document — moved or withdrawn.")
    else
      nil # network trouble is not news
    end
  end

  # Has a LATER edition appeared on the authority's own listing page? Looks for
  # the specific years we would expect next, rather than taking a maximum.
  def check_for_newer_edition(scheme, source)
    index = source["index_url"].presence
    built = source["form_year"].to_i
    return nil unless index && built.positive?

    body, status = fetch(index)
    return finding(scheme, :gone, source, "The listing page no longer resolves.") if status == :gone
    return nil unless status == :ok

    found = ((built + 1)..(built + LOOKAHEAD_YEARS)).find { |year| mentions_year?(body, year) }
    return nil unless found

    finding(scheme, :newer_year, source,
            "A #{found} edition is listed. The catalogue was built from #{built}.")
  end

  # Both the bare year and HMRC's "2026 to 2027" phrasing. Word-bounded, so
  # 2027 does not match inside 12027 or a media path.
  def mentions_year?(body, year)
    body.match?(/(?<!\d)#{year}(?!\d)/) || body.include?("#{year - 1} to #{year}")
  end

  def finding(scheme, kind, source, message, detail = nil)
    {
      scheme:  scheme,
      kind:    kind,
      message: message,
      detail:  detail,
      url:     source["url"] || source["index_url"],
      report_name: TaxSchemeConfig.report_name(scheme) || scheme
    }
  end

  # [body, :ok | :gone | :unreachable]. 404 and 410 mean the address changed,
  # which is worth an email. A timeout or DNS failure means the network, which
  # is not about the form at all.
  def fetch(url, limit: 4)
    return [ nil, :unreachable ] if limit.zero?

    uri = URI(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                               open_timeout: 10, read_timeout: 30) do |http|
      http.get(uri.request_uri, { "User-Agent" => "#{Hmrc::Config::PRODUCT_NAME} tax-form watch" })
    end

    case response
    when Net::HTTPSuccess     then [ response.body, :ok ]
    when Net::HTTPRedirection then fetch(URI.join(url, response["location"]).to_s, limit: limit - 1)
    when Net::HTTPNotFound, Net::HTTPGone then [ nil, :gone ]
    else [ nil, :unreachable ]
    end
  rescue StandardError => e
    Rails.logger.warn("TaxFormWatchJob: could not reach #{url} — #{e.class}: #{e.message}")
    [ nil, :unreachable ]
  end
end
