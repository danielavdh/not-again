Rails.application.configure do
  config.content_security_policy do |policy|
    # Derived, never written in, so a clone points at its own infrastructure
    # rather than at whoever wrote this. Any of them may be absent — no CDN and
    # no object storage is a valid way to run the app, and the policy simply
    # narrows to :self.
    https = ->(host) { host.presence && "https://#{host}" }

    cdn = https.(ENV["ASSET_HOST"])
    app = https.(ENV["APP_HOST"])

    # The receipts bucket's own origin. Built in ObjectStorage so this and
    # shrine.rb cannot drift apart — they have to agree exactly, or receipts
    # load in development and are refused by the policy in production.
    storage = ObjectStorage.bucket_origin

    cdn_only  = [ cdn ].compact
    documents = [ cdn, storage ].compact
    own_host  = [ app ].compact

    policy.object_src  :self, *[ storage ].compact
    # Additional directives from Rails default
    policy.base_uri :self
    policy.form_action :self, *own_host
    policy.frame_ancestors :self, *own_host
    policy.script_src_attr :none

    if Rails.env.development? || Rails.env.test?
      # One host in development, and it is localhost. This once listed several,
      # from a two-host arrangement that no longer exists.
      local_hosts = ["http://localhost:*"]
     policy.default_src :self, :http, *local_hosts
     policy.font_src    :self, :data, :http, *local_hosts
     policy.img_src     :self, :data, :http, :blob, *local_hosts
     policy.script_src  :self, :unsafe_inline, :unsafe_eval, :http, :blob, *local_hosts
     policy.style_src   :self, :http, :unsafe_inline, *local_hosts
     # Add this line to allow fetch requests
     policy.connect_src :self, :http, *local_hosts, "ws://localhost:*"
     policy.form_action :self, *local_hosts

   else
     policy.block_all_mixed_content
     policy.upgrade_insecure_requests
     policy.default_src :self, *cdn_only
     policy.font_src    :self, :data, *cdn_only
     policy.img_src     :self, :data, :blob, *documents
     policy.media_src   :self, *documents
     policy.script_src  :self, :blob, *cdn_only
     policy.style_src   :self, *cdn_only
     policy.connect_src :self, *documents
     policy.frame_src   :self, *[ storage ].compact
   end
   # Specify URI for violation reports
   # policy.report_uri "/csp-violation-report-endpoint"
  end

  # Nonces are off in development, where they would make unsafe_inline be
  # disregarded, and in production, where the app still carries inline scripts
  # and styles.
   if Rails.env.development? || Rails.env.production?
     # config.content_security_policy_nonce_generator = ->(request) {
     # request.session.id.to_s }
     config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
     config.content_security_policy_nonce_directives = %w(script-src style-src)
     # or allow inline styles:
     #config.content_security_policy_nonce_directives = %w(script-src)
   end

  config.content_security_policy_report_only = false
end
