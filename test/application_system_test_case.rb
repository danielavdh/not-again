require "test_helper"
require_relative "test_helpers/system_session_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include SystemSessionHelper

  # Plain localhost — no /etc/hosts entry anywhere, on this machine or on CI.
  # See SystemSessionHelper for why a public domain must not be used here.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
end
