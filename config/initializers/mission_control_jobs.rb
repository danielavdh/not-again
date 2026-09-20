Rails.application.config.to_prepare do
  MissionControl::Jobs::ApplicationController.class_eval do
    # Skip the default basic auth check provided by the gem
    skip_before_action :authenticate_by_http_basic, raise: false
  end
end