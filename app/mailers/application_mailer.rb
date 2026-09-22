class ApplicationMailer < ActionMailer::Base
  # Must be a sender the mail provider has authorised. A rejected mail RAISES in production,
  # so the sending job fails visibly and retries rather than vanishing silently.
  # Derived from APP_HOST via MAIL_FROM; no domain is hardcoded here.
  default from: -> { MAIL_FROM }
  # The mail gem's own Message-ID uses the machine's hostname, which in a container
  # is the server IP plus the container ID.
  default message_id: -> { "<#{SecureRandom.uuid}@#{Mail::Address.new(MAIL_FROM).domain}>" }
  layout 'mailer'
end

