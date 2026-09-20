# frozen_string_literal: true
require "test_helper"

# NO AUTHORITY IS NAMED OUTSIDE ITS OWN PLUGIN.
#
# An authority's name belongs in the YAML that declares it, in the connector
# class the YAML points at, and in that connector's own views and services.
# Anywhere else it is a leak, and every leak is something the next country's
# developer has to find and work around.
#
# The companion to submission_currency_test, which enforces the same rule for
# money. Both exist because the generic filing directory sits directly beside
# the authority-specific one, and it is genuinely easy to write a shared file as
# though it served the only authority that exists today.
#
# What it caught when written:
#
# · FilingController built Hmrc::FraudPreventionHeaders in a before_action, for
# EVERY connector's periods and submit pages
# · scripts/index.js started HMRC's browser fingerprint collector on every page
# of the app, for every admin, filing or not
# · the shared periods partial tested HMRC's own status letters, "F" and "O"
# · the submission dialog was id="hmrc-submission-modal"
# · Filing::Storage held two British form numbers in the generic archiver
# · the tax-category CSV — the one file a German accountant reads — was
# requested as ?tax=mtd, HMRC's programme name
class Filing::AuthorityNeutralityTest < ActiveSupport::TestCase
  # Every authority the app knows about, from the files that declare them. Not a
  # literal list: a new country's authority must be covered the day its tax
  # category file lands, without anyone remembering to add it here.
  AUTHORITIES = TaxSchemeConfig.countries
                                    .filter_map { |c| TaxSchemeConfig.authority(c) }
                                    .flat_map { |name| name.to_s.split(/\s+/) }
                                    .select { |word| word.length > 3 }
                                    .map(&:downcase)
                                    .uniq.freeze

  # THE PLUGINS. A class the YAML points at may carry its authority's name —
  # that name IS the wiring, not a leak: `connector: hmrc_mtd` resolves to
  # Filing::HmrcMtd and `parser: hmrc_csv` to Rates::HmrcCsvParser, so renaming
  # the class would break the declaration that selects it.
  #
  # That is the honest floor: an authority may be named in the YAML that
  # declares it, in the class that YAML names, and in that class's own
  # directory. Nowhere else, which is what the sweep below enforces.
  OWNED_PATHS = %w[
    app/services/hmrc
    app/services/filing/hmrc_mtd.rb
    app/views/filing/hmrc_mtd
    app/jobs/hmrc
    app/views/admin_mailer/hmrc_sandbox_check_failed.html.erb
    app/views/admin_mailer/hmrc_sandbox_check_failed.text.erb
    app/services/rates/hmrc_csv_parser.rb
    app/services/rates/estv_xml_parser.rb
  ].freeze

  # The two registries that list their plugins by name, which is their whole
  # job. Stripped before the sweep reads the file rather than exempting the
  # file, so the rest of Base and the rest of RateSourceConfig stay covered.
  REGISTRY_PATTERNS = [
    /CONNECTORS\s*=\s*%w\[[^\]]*\]/,
    /FORMATS\s*=\s*%w\[[^\]]*\]/
  ].freeze

  def authority_words_in(body)
    stripped = body.gsub(/<%#.*?%>/m, "")          # ERB comments
                   .gsub(/^\s*#.*$/, "")            # Ruby / YAML comments
                   .gsub(%r{/\*.*?\*/}m, "")        # CSS-style block comments
                   .gsub(%r{^\s*//.*$}, "")         # JS line comments
    REGISTRY_PATTERNS.each { |pattern| stripped = stripped.sub(pattern, "") }
    AUTHORITIES.select { |word| stripped.downcase.include?(word) }
  end

  test "the authority list is derived and not empty" do
    assert_includes AUTHORITIES, "hmrc"
    assert_includes AUTHORITIES, "elster"
    assert_not_includes AUTHORITIES, "ecb", "rate sources are tier 1 and not authorities"
  end

  # The shared filing views serve every connector. One of them naming an
  # authority is the bug that showed a German EÜR under a British heading.
  test "no generic filing view names an authority" do
    views = Dir[Rails.root.join("app/views/filing/*.erb")]
    assert views.any?, "expected generic filing views to exist"

    views.each do |path|
      found = authority_words_in(File.read(path))
      assert_empty found,
                   "#{File.basename(path)} names #{found.join(', ')}. A shared filing view " \
                   "must reach an authority only through the connector — see " \
                   "Filing::Base#authority and #panel_partial."
    end
  end

  # The filing CONTROLLER resolves connectors; it must never reach into one.
  test "the filing controller names no authority" do
    body  = File.read(Rails.root.join("app/controllers/filing_controller.rb"))
    found = authority_words_in(body)
    assert_empty found,
                 "FilingController names #{found.join(', ')}. Whatever it needs belongs " \
                 "behind a method on Filing::Base that the connector overrides — " \
                 ".prepare_request and .registered_callback_path are the two that exist."
  end

  # Base declares the contract. A connector's name in it means the contract has
  # been shaped around one authority.
  test "Filing::Base names no authority outside its comments" do
    body  = File.read(Rails.root.join("app/services/filing/base.rb"))
    found = authority_words_in(body)
    assert_empty found, "Filing::Base names #{found.join(', ')} outside the registry"
  end

  # The archive is regime-agnostic by design — the README says so. It stopped
  # being so when two SA form numbers were written into it.
  test "the submission archive names no authority and no form" do
    body  = File.read(Rails.root.join("app/services/filing/storage.rb"))
    found = authority_words_in(body)
    assert_empty found, "Filing::Storage names #{found.join(', ')}"
    assert_no_match(/SA10\d/, body.gsub(/^\s*#.*$/, ""),
                    "form references come from form_code: in the scheme's tax category file")
  end

  # An obligation's status is the app's vocabulary, not an authority's alphabet.
  test "no shared file tests an authority's own status codes" do
    shared = Dir[Rails.root.join("app/views/filing/*.erb")] +
             [ Rails.root.join("app/services/filing/base.rb").to_s,
               Rails.root.join("app/controllers/filing_controller.rb").to_s ]

    shared.each do |path|
      body = File.read(path).gsub(/<%#.*?%>/m, "").gsub(/^\s*#.*$/, "")
      assert_no_match(/\[:status\]\s*==\s*["']/, body,
                      "#{File.basename(path)} compares a status against a literal. " \
                      "Use Filing::Base::STATUS_OPEN / STATUS_FULFILLED; the " \
                      "connector translates its authority's own codes at the edge.")
    end
  end

  # Everything under app/ that is not a connector's own territory.
  test "no authority is named anywhere outside its own plugin" do
    roots = %w[app/controllers/acc app/models/acc app/services/acc app/views/acc
               app/jobs/acc app/helpers/acc app/lib/acc]
    owned = OWNED_PATHS.map { |p| Rails.root.join(p).to_s }

    offenders = roots.flat_map { |root| Dir[Rails.root.join(root, "**", "*")] }
                     .select { |p| File.file?(p) }
                     .reject { |p| owned.any? { |o| p == o || p.start_with?("#{o}/") } }
                     .filter_map { |p|
                       found = authority_words_in(File.read(p))
                       [ p.sub("#{Rails.root}/", ""), found ] if found.any?
                     }

    assert_empty offenders,
                 "these files name an authority but are not part of its connector:\n" +
                 offenders.map { |p, w| "  #{p} — #{w.join(', ')}" }.join("\n")
  end
end
