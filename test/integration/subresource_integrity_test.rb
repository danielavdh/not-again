require "test_helper"

# Assets are served from a CDN. Every stylesheet and script the page names must
# carry its hash, or a CDN serving an altered file goes unnoticed.
class SubresourceIntegrityTest < ActionDispatch::IntegrationTest
  def assert_every_asset_hashed
    stylesheets = css_select("link[rel=stylesheet]")
    assert stylesheets.any?, "no stylesheet on the page"
    stylesheets.each do |link|
      assert_match(/\Asha384-/, link["integrity"].to_s, "#{link['href']} has no integrity hash")
      # Without it a cross-origin (CDN) file cannot be checked, and the browser refuses it.
      assert_equal "anonymous", link["crossorigin"], "#{link['href']} lacks crossorigin"
    end

    importmap = JSON.parse(css_select("script[type=importmap]").first.text)
    imports   = importmap.fetch("imports").values
    hashed    = importmap.fetch("integrity", {})
    assert imports.any?, "the importmap names no modules"
    imports.each do |path|
      assert_match(/\Asha384-/, hashed[path].to_s, "#{path} has no integrity hash")
    end
  end

  test "the public layout hashes its assets" do
    get root_url(locale: :en)
    assert_response :success
    assert_every_asset_hashed
  end

  test "the signed-in layout hashes its assets, including the form's extra stylesheet" do
    sign_in_as(admins(:one))
    get new_journal_entry_url(locale: :en)
    assert_response :success
    assert_select "link[rel=stylesheet][href*='tom-select']"
    assert_every_asset_hashed
  end
end
