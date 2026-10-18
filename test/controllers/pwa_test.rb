# frozen_string_literal: true

require "test_helper"

# A service worker caches its shell with one cache.addAll, and that call is
# all-or-nothing: one URL that 404s aborts the install, so the app has no
# offline shell at all — silently, because nothing in the app is watching.
#
# Written after three images carried over from the old site (welcome_index*.jpg)
# made the worker itself 500 for months.
class PwaTest < ActionDispatch::IntegrationTest
  test "the service worker renders, so there is something to install" do
    get "/service-worker.js"
    assert_response :success
  end

  test "every URL the service worker caches can actually be fetched" do
    get "/service-worker.js"
    urls = response.body.scan(/"(\/[^"]*)"/).flatten.uniq

    assert_operator urls.size, :>=, 5, "the cache list should not have emptied itself"

    urls.each do |url|
      get url
      assert_includes 200..399, response.status,
        "#{url} is in URLS_TO_CACHE but answers #{response.status} — " \
        "one bad URL aborts cache.addAll and the whole install with it"
    end
  end

  test "the manifest renders, since the service worker caches it" do
    get "/manifest.json"
    assert_response :success
    assert_includes response.body, "share_target"
  end
end
