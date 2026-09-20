# frozen_string_literal: true
require "test_helper"

# Checks the Gemfile CONFIGURATION directly rather than runtime state, so it
# fails even when something else masks the problem.
#
# Ordinary use of Zip cannot catch this: selenium-webdriver requires "zip"
# itself as a side effect, so `Zip` looks loaded in every test run whether or
# not rubyzip's own Gemfile entry is right — which is why download_selected
# worked in every test and raised NameError on a real development boot.
class GemfileRequiresTest < ActiveSupport::TestCase
  test "rubyzip is configured to require 'zip', not the default guessed name" do
    dep = Bundler.load.dependencies.find { |d| d.name == "rubyzip" }
    assert dep, "rubyzip should still be in the Gemfile"
    assert_equal [ "zip" ], dep.autorequire,
      "rubyzip's own file is lib/zip.rb, not lib/rubyzip.rb — without require: \"zip\" " \
      "Bundler's naive guess silently finds nothing, and Zip is never defined outside test"
  end
end
