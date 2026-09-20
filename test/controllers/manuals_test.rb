require "test_helper"

# The manuals broke silently once during the extraction: the layout they used
# rendered a menu partial that had gone with the main site. Two green suites and
# nobody noticed, because nothing asked for the page.
class ManualsTest < ActionDispatch::IntegrationTest
  # --- reachable by everyone, which is the whole point ---

  test "a signed-out visitor can read both manuals" do
    get easy_manual_path(locale: :en)
    assert_response :success

    get pro_manual_path(locale: :en)
    assert_response :success
  end

  test "every language of every manual renders" do
    I18n.available_locales.each do |locale|
      get easy_manual_path(locale: locale)
      assert_response :success, "the easy manual is broken in #{locale}"

      get pro_manual_path(locale: locale)
      assert_response :success, "the pro manual is broken in #{locale}"
    end
  end

  # Adding a language is documented as "one line in LANGUAGES and two yml
  # files". It is not: every document in app/views/help needs its own template
  # too, and nothing else would say so. The controller falls back to English
  # rather than raising, so the failure is silent — a Dutch reader quietly gets
  # an English manual and no error anywhere.
  #
  # WelcomeController::HELP_DOCS, not a glob of *_en.html.erb: a doc that loses
  # its own English file must not just drop out of what this checks. The English
  # file itself is guarded at boot, in 00_locale_guard.rb.
  test "every language has a template for every document in app/views/help" do
    dir = Rails.root.join("app/views/help")

    missing = WelcomeController::HELP_DOCS.flat_map { |doc|
      I18n.available_locales.reject { |l| dir.join("#{doc}_#{l}.html.erb").exist? }
          .map { |l| "#{doc}_#{l}.html.erb" }
    }

    assert_empty missing,
                 "untranslated documents in app/views/help — readers of those " \
                 "languages silently get English:\n  #{missing.join("\n  ")}"
  end

  # --- public does not mean the app is open ---

  test "reading a manual does not sign anyone in" do
    get easy_manual_path(locale: :en)
    assert_response :success

    get dashboard_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en),
                         "reading a manual must not have created a session"
  end

  test "a signed-out reader is offered no way into the app" do
    get easy_manual_path(locale: :en)
    assert_response :success
    assert_select "nav#menu a", false,
                  "a visitor with no session was shown navigation into the app"
  end

  # --- getting back out ---

  # These are long documents, and nobody should have to scroll to the bottom, or
  # back to the top, to leave one.
  #
  # The claim is POSITION, not quantity: counting the nav blocks would pass with
  # both stacked at the top, which is the case this rules out.
  test "a manual can be left from either end without scrolling" do
    get easy_manual_path(locale: :en)
    body = response.body

    first_way_out = body.index("crud_navigation")
    last_way_out  = body.rindex("crud_navigation")
    text_starts   = body.index("<h1")
    text_ends     = body.rindex("</h2>")

    assert first_way_out < text_starts, "no way out above the text"
    assert last_way_out  > text_ends,   "no way out below the text"
  end

  # back_to_referer_path can dead-end: arrive from a search engine or from
  # somebody else's site and "back" has nowhere useful to go. The front page is
  # the escape hatch, and the reason a reader cannot get trapped in a manual.
  test "a manual offers the front page as well as the way you came" do
    get easy_manual_path(locale: :en)
    assert_select "div.crud_navigation a[href=?]", root_path(locale: :en),
                  { minimum: 1 }, "the only way out was the referer"
  end

  test "back returns you to the page that sent you here" do
    sign_in_as admins(:one)
    get easy_manual_path(locale: :en), headers: { "HTTP_REFERER" => accounts_url(locale: :en) }

    assert_select "div.crud_navigation a" do |links|
      assert_equal accounts_url(locale: :en), links.first["href"]
    end
  end

  # The referer is whatever the browser sends. Without a same-origin check, a
  # link from someone else's site would turn our own back button into a link
  # back to theirs.
  test "back ignores a referer from another site" do
    sign_in_as admins(:one)
    get easy_manual_path(locale: :en), headers: { "HTTP_REFERER" => "https://example.com/somewhere" }

    assert_select "div.crud_navigation a" do |links|
      assert_equal dashboard_path(locale: :en), links.first["href"]
    end
  end

  test "back has somewhere to go for a reader who arrived from nowhere" do
    get easy_manual_path(locale: :en)
    assert_select "div.crud_navigation a" do |links|
      assert_equal root_path(locale: :en), links.first["href"],
                   "a visitor with no session and no referer belongs on the front page"
    end
  end

  # --- the front page is not the app ---

  test "being signed in does not turn the landing page into the app" do
    sign_in_as admins(:one)
    get root_path(locale: :en)
    assert_response :success
    assert_select "nav#menu", false,
                  "the landing page keeps its own chrome for everyone"
  end
end
