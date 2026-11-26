require "test_helper"
require_relative "test_helpers/system_session_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include SystemSessionHelper

  # Plain localhost — no /etc/hosts entry anywhere, on this machine or on CI.
  # See SystemSessionHelper for why a public domain must not be used here.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    # Chrome 158 rejects the storage clear-up Capybara 3.40.0 sends after every
    # test (teamcapybara/capybara#2865), so every test errors in teardown.
    # Pinned only while that version is installed: a Capybara update lifts it,
    # and the system tests then say whether the fix is real.
    #
    # Rails has already asked Selenium Manager for a browser and driver by the
    # time this block runs, and set both to the installed Chrome, so the pinned
    # version has to be resolved again from scratch. Selenium Manager downloads
    # it, here and on CI.
    if Gem.loaded_specs["capybara"].version <= Gem::Version.new("3.40.0")
      options.browser_version = "157"
      options.binary = nil
      Selenium::WebDriver::Chrome::Service.driver_path = nil
      finder = Selenium::WebDriver::DriverFinder.new(options, Selenium::WebDriver::Chrome::Service.new)
      options.binary = finder.browser_path
      Selenium::WebDriver::Chrome::Service.driver_path = finder.driver_path
    end
  end
end
