class ApplicationMailer < ActionMailer::Base
  # Must be a sender Brevo has authorised. A rejected mail RAISES in production,
  # so the sending job fails visibly and retries rather than vanishing silently.
  # Derived from APP_HOST via MAIL_FROM; no domain is hardcoded here.
  default from: -> { MAIL_FROM }
  layout 'mailer'
end

