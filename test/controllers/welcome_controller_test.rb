# frozen_string_literal: true

require "test_helper"

class WelcomeControllerTest < ActionDispatch::IntegrationTest
  # ---- high-contrast toggle -------------------------------------------------

  test "POST /contrast on=1 forces high contrast and redirects back" do
    post contrast_path(locale: :en), params: { on: "1" }, headers: { "HTTP_REFERER" => root_url(locale: :en) }
    assert_redirected_to root_url(locale: :en)
    assert_equal "1", cookies[:high_contrast]
  end

  test "POST /contrast on=0 forces contrast off" do
    post contrast_path(locale: :en), params: { on: "0" }
    assert_equal "0", cookies[:high_contrast]
  end

  test "POST /contrast with a blank value clears the cookie, back to following the OS" do
    post contrast_path(locale: :en), params: { on: "1" }
    assert_equal "1", cookies[:high_contrast]

    post contrast_path(locale: :en), params: { on: "" }
    assert cookies[:high_contrast].blank?, "the cookie should be cleared, not kept"
  end

  test "POST /contrast falls back to root when there is no referer" do
    post contrast_path(locale: :en), params: { on: "1" }
    assert_redirected_to root_url(locale: :en)
  end

  # ---- the toggle is on the page -----------------------------------------

  test "the landing page carries a high-contrast toggle that posts to /contrast" do
    get root_path(locale: :en)
    assert_response :success
    assert_select "form[action=?][method=post] button", contrast_path(locale: :en)
    # the icon sprite is on the public layout now, so the ◐ glyph resolves
    assert_select "svg.svg-definitions symbol#contrast", 1
    assert_select "form.contrast-toggle use[href=?]", "#contrast"
  end

  test "a high_contrast=1 cookie puts the class on <html>" do
    cookies[:high_contrast] = "1"
    get root_path(locale: :en)
    assert_select "html.high-contrast"
  end

  test "a high_contrast=0 cookie forces the off class even against the OS preference" do
    cookies[:high_contrast] = "0"
    get root_path(locale: :en)
    assert_select "html.contrast-normal"
  end
end
