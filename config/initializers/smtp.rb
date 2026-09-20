# frozen_string_literal: true

# ONE place that reads the outgoing-mail settings, mirroring
# 00_object_storage.rb for the S3 settings.
#
# The values come from two places, and the environment wins: credentials `smtp:`
# (server / port / username / password), how the Kamal installation is
# configured; or the SMTP_* environment variables, for a deploy with no master
# key where credentials cannot be edited.
#
# production.rb and development.rb both set delivery_method = :smtp; this fills
# in the settings for whichever is running. Test delivers :test and ignores
# this.
smtp_port = ENV["SMTP_PORT"].presence || Rails.application.credentials.dig(:smtp, :port)

Rails.application.config.action_mailer.smtp_settings = {
  address:   ENV["SMTP_ADDRESS"].presence  || Rails.application.credentials.dig(:smtp, :server),
  port:      smtp_port&.to_i,
  user_name: ENV["SMTP_USERNAME"].presence || Rails.application.credentials.dig(:smtp, :username),
  password:  ENV["SMTP_PASSWORD"].presence || Rails.application.credentials.dig(:smtp, :password),
  authentication: :plain,
  enable_starttls_auto: true
}
