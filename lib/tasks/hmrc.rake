# frozen_string_literal: true

namespace :hmrc do
  # Scores our fraud prevention headers against HMRC's own Test Fraud Prevention
  # Headers API. Run on the production server so the outbound IP matches Gov-
  # Vendor-Public-IP:
  #
  # bin/rails hmrc:fph_validate
  #
  # Requires the app to be subscribed to "Test Fraud Prevention Headers" in the
  # HMRC developer hub. Always targets sandbox, since the validator only exists
  # there, so it keeps working after production go-live. Shared logic is in
  # Hmrc::FphValidator, also used by the weekly SandboxHealthcheckJob.
  desc "Validate our fraud prevention headers against HMRC's Test FPH API (sandbox)"
  task fph_validate: :environment do
    unless Hmrc::Config.sandbox_configured?
      abort "No sandbox credentials (hmrc.sandbox.*) configured — nothing to validate against."
    end

    result  = Hmrc::FphValidator.run
    headers = Hmrc::FphValidator.representative_headers

    puts "Sent #{headers.size} fraud prevention headers:"
    headers.each_key { |k| puts "  - #{k}" }
    puts
    puts result.summary
    result.errors.each   { |e| puts "  ERROR    #{Array(e['headers']).join(', ')} — #{e['message']}" }
    result.warnings.each { |w| puts "  WARNING  #{Array(w['headers']).join(', ')} — #{w['message']}" }
    puts "\nDone. VALID_HEADERS = compliant; fix ERRORs, review WARNINGs."
  end
end
