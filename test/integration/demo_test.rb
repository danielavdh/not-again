require "test_helper"

# The demo is a public auto-login into a bookkeeping app. That is a door, and a
# door deserves tests that try to walk through it sideways.
#
# It rests on machinery that is already load-bearing elsewhere — AdminEntity
# access levels, require_write_access, the per-entity writable_* scopes — so
# these tests are not really about the demo: they assert that a read-only link
# means read-only, from the one account a stranger can reach without a password.
class DemoTest < ActionDispatch::IntegrationTest
  setup do
    @entity = entities(:family_biz)          # code 10, owns the accounts below
    @theirs = accounts(:bank_gbp)            # entity 10 — the demo may read it
    @others = accounts(:boss_bank)           # entity 01 — the demo may not see it

    # The demo gets this entity to itself, which is what demo:seed builds in
    # production: its own entity, no real admin on it. AdminEntity refuses to
    # let a public passwordless account share an entity with a real one, so the
    # fixture links have to go before the demo link can exist.
    @entity.admin_entities.joins(:admin).where(admins: { demo: false }).destroy_all

    @demo = Admin.create!(username: "demo-under-test", demo: true,
                          preferred_currency: "GBP", password: SecureRandom.hex(16))
    AdminEntity.create!(admin: @demo, entity: @entity, access_level: :read_only)
  end

  def enter_the_demo
    post demo_path(locale: :en)
    assert_redirected_to dashboard_path(locale: :en)
    follow_redirect!
  end

  # --- the front door ---

  test "the demo page is public" do
    get demo_path(locale: :en)
    assert_response :success
  end

  test "entering the demo lands a stranger on the dashboard" do
    enter_the_demo
    assert_response :success
  end

  # A GET that starts a session can be fired by an <img> tag on someone else's
  # page. /demo answers GET with the description and nothing else.
  test "merely looking at the demo page starts no session" do
    assert_no_difference("Session.count") { get demo_path(locale: :en) }
  end

  # --- what a demo visitor cannot do ---

  test "cannot create an account" do
    enter_the_demo
    assert_no_difference("Account.count") do
      post accounts_path(locale: :en),
           params: { account: { code: "110777", name: "Mine now", account_type: :asset, currency: "GBP" } }
    end
  end

  test "cannot rename an account it can see" do
    enter_the_demo
    was = @theirs.name
    patch account_path(@theirs, locale: :en), params: { account: { name: "Renamed by a stranger" } }
    assert_equal was, @theirs.reload.name
  end

  test "cannot destroy an account" do
    enter_the_demo
    assert_no_difference("Account.count") { delete account_path(@theirs, locale: :en) }
  end

  test "cannot write a journal entry" do
    enter_the_demo
    assert_no_difference("JournalEntry.count") do
      post journal_entries_path(locale: :en), params: {
        journal_entry: { entry_date: Date.current, memo: "Free money",
                         postings_attributes: {
                           "0" => { account_id: @theirs.id, entry_type: "debit",  amount: "100" },
                           "1" => { account_id: accounts(:income_sales).id, entry_type: "credit", amount: "100" }
                         } }
      }
    end
  end

  # The demo MAY open the forms: a demo that cannot show the entry screens is
  # not showing the app. Looking at a form writes nothing, which the test below
  # this one is what proves.
  test "can open the forms, which is the point of a demo" do
    enter_the_demo

    [ new_account_path(locale: :en),
      new_deposit_account_path(@theirs, locale: :en),
      new_withdrawal_account_path(@theirs, locale: :en),
      new_transfer_account_path(@theirs, locale: :en) ].each do |path|
      get path
      assert_response :success, "#{path} should be visible to a demo visitor"
    end
  end

  # Filing is not looking. #connect opens an OAuth handshake with a real tax
  # authority over GET, so it goes with the writes rather than with the reads.
  test "cannot start a conversation with a tax authority" do
    enter_the_demo
    get filing_connect_entity_path(@entity, locale: :en)
    assert_response :redirect
  end

  test "can read its own profile but not the admin list" do
    enter_the_demo

    get admin_path(@demo, locale: :en)
    assert_response :success

    get admins_path(locale: :en)
    assert_response :redirect, "the demo must not see who else has an account here"
  end

  # Self-access for every admin (ensure_full_access_or_self) adds a branch
  # exempting "my own id" with no method restriction of its own, which silently
  # overrides demo's GET-only rule for its own id specifically. Confirmed
  # exploitable — the username actually changed — before the !demo? guard.
  test "can open its own edit form but cannot save it" do
    enter_the_demo
    original_username = @demo.username

    get edit_admin_path(@demo, locale: :en)
    assert_response :success

    patch admin_path(@demo, locale: :en), params: { admin: { username: "demo_hijacked" } }
    assert_response :redirect
    assert_equal original_username, @demo.reload.username, "the demo must never be able to save its own record"
  end

  test "its own show page offers neither Edit nor Leave" do
    enter_the_demo
    get admin_path(@demo, locale: :en)
    assert_select "a[href=?]", edit_admin_path(@demo), text: "Edit", count: 0
    assert_select "div.offboarding", 0
  end

  # skip_before_action :require_write_access for SELF_SERVICE_ACTIONS, added to
  # let a genuine read_only admin leave, removes require_write_access's OWN demo
  # branch along with it — and that branch was what had been blocking demo from
  # #leave all along, coincidentally. Confirmed exploitable: demo destroyed the
  # link to its own sandbox entity. EntitiesController#leave now refuses demo
  # explicitly, first, regardless of that skip.
  test "cannot leave its own entity, even by posting directly to the action" do
    enter_the_demo
    assert_no_difference("AdminEntity.count") do
      delete leave_entity_path(@entity, locale: :en)
    end
    assert AdminEntity.exists?(admin_id: @demo.id, entity_id: @entity.id),
           "the demo's link to its own sandbox entity must survive"
  end

  test "cannot upload a receipt" do
    enter_the_demo
    assert_no_difference("Receipt.count") do
      post receipts_path(locale: :en), params: { receipt: { entity_id: @entity.id } }
    end
  end

  test "cannot reach the admin list" do
    enter_the_demo
    get admins_path(locale: :en)
    assert_response :redirect
    assert_not_equal admins_path(locale: :en), response.location
  end

  test "cannot add a currency" do
    enter_the_demo
    assert_no_difference("Currency.count") do
      post currencies_path(locale: :en), params: { currency: { code: "XXX", symbol: "¤", position: 99 } }
    end
  end

  # A long custom report turns each posting into a link that opens the entry it
  # came from. That is a large part of what there is to see, and the demo can
  # open those forms — only the link was withheld.
  test "postings on a long report are links the demo can follow" do
    assert @demo.may_open_entry_forms?, "the demo must be offered the entry forms"
    assert_not admins(:read_only).may_open_entry_forms?,
               "a read-only accountant still gets plain text — the journal entry view already shows them everything"
  end

  # Tax setup is a form and the demo may look at forms. What it can submit —
  # update_tax is a PATCH — is refused by the same rule as everything else.
  test "the demo can read the tax setup screen but not save it" do
    enter_the_demo

    get edit_tax_entity_path(@entity, locale: :en)
    assert_response :success

    was = @entity.tax_schemes
    patch update_tax_entity_path(@entity, locale: :en), params: { entity: { tax_schemes: [ "vat" ] } }
    assert_equal was, @entity.reload.tax_schemes, "a refused write must not have landed"
  end

  # Asking to leave when you are already out is not a reason to be asked for a
  # password. A stale cookie used to turn the logout button into the login page.
  test "logging out with no session lands on the front page, not the login form" do
    delete session_path(locale: :en)
    assert_redirected_to root_path(locale: :en)
  end

  # --- the receipt helper ---

  # The third door: the person whose whole role is photographing receipts. They
  # land on the uploader and can reach nothing else, which is the real role
  # rather than a demo restriction.
  test "the receipt door lands on the uploader and nowhere else" do
    helper = Admin.create!(username: "demo-receipts-under-test", demo: true,
                           password: SecureRandom.hex(16))
    AdminEntity.create!(admin: helper, entity: @entity, access_level: :upload_receipts)

    post demo_path(locale: :en, version: "receipts")
    assert_redirected_to upload_standalone_receipts_path(locale: :en)

    get dashboard_path(locale: :en)
    assert_redirected_to upload_standalone_receipts_path(locale: :en),
                         "an upload-only account has nowhere else to be"
  end

  # The uploader lists accessible_receipts.unlinked.where(uploaded_by:), so a
  # helper who has photographed nothing sees an empty page. Two conditions, and
  # a receipt failing either must not appear: Receipt#link_to_posting clears
  # uploaded_by precisely so a booked receipt leaves the shoebox.
  test "the receipt helper sees the shoebox, and nothing that is already booked" do
    helper = Admin.create!(username: "demo-receipts-under-test", demo: true,
                           password: SecureRandom.hex(16))
    AdminEntity.create!(admin: helper, entity: @entity, access_level: :upload_receipts)

    mine   = receipts(:unlinked_receipt)
    booked = receipts(:linked_receipt)
    mine.update_column(:uploaded_by_id, helper.id)
    booked.update_column(:uploaded_by_id, helper.id)   # the state linking undoes

    post demo_path(locale: :en, version: "receipts")
    follow_redirect!
    assert_response :success

    # Each row carries its own delete button, so the form's action is a per-
    # receipt
    # hook — and asserting on it proves the row is actionable, not merely
    # printed.
    assert_select "form[action='#{delete_own_receipt_path(mine, locale: :en)}']",
                  { minimum: 1 }, "the helper's own unlinked receipt was not listed"
    assert_select "form[action='#{delete_own_receipt_path(booked, locale: :en)}']",
                  false, "a receipt already linked to a posting was offered as unfiled"
  end

  # receipts_controller skips require_write_access for :create and :delete_own,
  # so those two are the one place in the app where a demo could actually write
  # — and an upload-only account has receipt access by definition, which is
  # exactly what would have let it.
  test "the receipt helper cannot actually upload anything" do
    helper = Admin.create!(username: "demo-receipts-under-test", demo: true,
                           password: SecureRandom.hex(16))
    AdminEntity.create!(admin: helper, entity: @entity, access_level: :upload_receipts)

    post demo_path(locale: :en, version: "receipts")

    assert_no_difference("Receipt.count") do
      post receipts_path(locale: :en), params: { receipt: { entity_id: @entity.id } }
    end
  end

  # --- the two doors ---

  test "the plain door hides journal entries, the pro door shows them" do
    pro = Admin.create!(username: "demo-pro-under-test", demo: true,
                        preferred_currency: "GBP", show_journal_entries: true,
                        password: SecureRandom.hex(16))
    AdminEntity.create!(admin: pro, entity: @entity, access_level: :read_only)

    post demo_path(locale: :en)
    follow_redirect!
    assert_select "nav#menu a[href=?]", journal_entries_path(locale: :en), false,
                  "the plain demo should not offer journal entries"

    post demo_path(locale: :en, version: "pro")
    follow_redirect!
    assert_select "nav#menu a[href=?]", journal_entries_path(locale: :en)
  end

  # --- and cannot see past its own entity ---

  test "cannot see an account belonging to another entity" do
    enter_the_demo
    get account_path(@others, locale: :en)
    assert_response :redirect, "entity 01's books were reachable from the demo"
  end

  test "the demo account is linked to exactly one entity, read-only" do
    assert_equal [ "read_only" ], @demo.admin_entities.map(&:access_level).uniq
    assert_not @demo.sudo?
    assert_not @demo.full_access?, "a single full_access link would disable the blanket write guard"
    assert @demo.read_only?
  end

  # --- second factor ---

  # OTP is off outside production, so without this stub the demo would appear to
  # work and then meet a QR code on the live site. A stranger has no second
  # factor to offer and nothing to protect, so the demo account is exempt.
  test "a stranger is not asked for a second factor" do
    Admin.stub(:otp_required?, true) do
      enter_the_demo
      assert_response :success
      assert_no_match(/otp/, response.body.to_s[0, 200].to_s.downcase)
    end
  end

  # --- when there is no demo ---

  test "with no demo account there is no way in and no button" do
    @demo.admin_entities.destroy_all
    @demo.destroy!

    get root_path(locale: :en)
    assert_select "a[href=?]", demo_path(locale: :en), false, "the front page offered a demo that does not exist"

    post demo_path(locale: :en)
    assert_redirected_to demo_path(locale: :en)
  end

  test "the front page offers the demo when there is one" do
    get root_path(locale: :en)
    assert_select "a[href=?]", demo_path(locale: :en)
  end

  # A demo visitor never asked to be remembered, and their session row is gone
  # within two hours, so a 20-year cookie is a dead pointer left in a stranger's
  # browser. A real admin still gets the permanent one, because staying logged
  # in is the point.
  test "a demo leaves no cookie behind the browser, a real admin does" do
    # Read Set-Cookie from the POST itself. Following the redirect replaces the
    # response, and the next page sets no session cookie — so an assertion made
    # after follow_redirect! matches an empty string and passes either way.
    post demo_path(locale: :en)
    demo_cookie = session_cookie_header
    assert demo_cookie.present?, "no session cookie was set at all"
    assert_no_match(/expires=/i, demo_cookie, "the demo was given a cookie that outlives the browser")

    reset!
    post session_url(locale: :en), params: { username: admins(:one).username, password: "password" }
    admin_cookie = session_cookie_header
    assert admin_cookie.present?, "no session cookie was set at all"
    assert_match(/expires=/i, admin_cookie, "a real admin lost their staying-logged-in cookie")
  end

  def session_cookie_header
    Array(response.headers["Set-Cookie"]).flat_map { |h| h.split("\n") }.grep(/\Asession_id=/).join
  end

  # The strip is one shared partial on two pages, and it builds its hrefs with
  # url_for(locale:), which regenerates THIS page in the other locale. Hard-code
  # a path there, or let a stray param leak in, and a reader switching language
  # on /demo is silently dropped on the front page — nothing else would notice,
  # because every link still resolves.
  test "switching language keeps you on the page you were reading" do
    get demo_path(locale: :en)
    assert_response :success

    LANGUAGES.each do |_name, code|
      assert_select ".langs a[href=?]", demo_path(locale: code)
    end
    assert_select ".langs a[href=?]", root_path(locale: :de), false,
                  "the language strip sent a demo reader to the front page"
  end

  # --- the way out of the demo ---

  # The front page's login button is a request to do REAL work. Bouncing a demo
  # visitor back into the demo makes the button a lie and leaves them no way out
  # except finding the logout inside the app.
  test "asking for the login ends the demo session and shows the form" do
    enter_the_demo
    assert Session.exists?(admin: @demo)

    get new_session_path(locale: :en)
    assert_response :success
    assert_select "form[action=?]", session_path(locale: :en)
    assert_not Session.exists?(admin: @demo),
               "the demo session survived a request for the real login form"
  end

  # Terminating a session mid-request is not enough on its own: Current still
  # holds the destroyed row and Current.admin delegates to it, so the page would
  # render the demo's signed-in menu around the login form.
  test "the login form is drawn for a stranger, not around the demo's menu" do
    enter_the_demo
    get new_session_path(locale: :en)

    assert_select "nav#menu a[href=?]", dashboard_path(locale: :en), false,
                  "the demo's menu was still drawn around the login form"
    assert_select "form[action=?] input[name=?]", session_path(locale: :en), "username"
  end

  test "a real admin opening the login page is not logged out by it" do
    sign_in_as admins(:one)

    get new_session_path(locale: :en)
    assert_response :redirect
    assert Session.exists?(admin: admins(:one)),
           "opening the login page threw a real admin out of their own books"
  end

  # ensure_sudo must not send a non-sudo admin to the login form. Now that
  # /login deliberately ends a demo session, that route would throw a demo
  # visitor out of the demo for opening a page they were never offered.
  test "a sudo-only page refuses the demo without ending the demo" do
    enter_the_demo

    get entities_path(locale: :en)
    assert_redirected_to dashboard_path(locale: :en)
    assert Session.exists?(admin: @demo), "a refusal logged the demo out"
  end

  # The same fix, for the account it was always wrong for: a signed-in admin who
  # is simply not allowed is told so. A login form says "you were logged out",
  # which is untrue.
  test "a sudo-only page refuses a signed-in admin instead of offering a login" do
    sign_in_as admins(:one)

    get entities_path(locale: :en)
    assert_response :redirect
    assert_not_equal new_session_path(locale: :en), response.location,
                     "a refusal was dressed up as an expired session"
    assert Session.exists?(admin: admins(:one))
  end

  # --- pressing the same door twice ---

  test "re-entering the same demo door reuses the session it already has" do
    enter_the_demo

    assert_no_difference("Session.count") { post demo_path(locale: :en) }
    assert_redirected_to dashboard_path(locale: :en)
  end

  test "changing doors replaces the session rather than leaving one behind" do
    pro = Admin.create!(username: "demo-pro-under-test", demo: true,
                        preferred_currency: "GBP", show_journal_entries: true,
                        password: SecureRandom.hex(16))
    AdminEntity.create!(admin: pro, entity: @entity, access_level: :read_only)

    enter_the_demo
    assert_no_difference("Session.count") { post demo_path(locale: :en, version: "pro") }

    assert_not Session.exists?(admin: @demo), "the plain demo's session was orphaned"
    assert Session.exists?(admin: pro)
  end

  # --- somebody else's real session ---

  # Silently swapping a real admin's session for the demo's would sign them out
  # of their own books. Refuse, and leave their session where it was.
  test "entering the demo does not sign a real admin out of their own books" do
    sign_in_as admins(:one)
    post demo_path(locale: :en)
    assert_redirected_to demo_path(locale: :en)

    get dashboard_path(locale: :en)
    assert_response :success
    assert Session.exists?(admin: admins(:one)), "their own session was thrown away"
    assert_not Session.exists?(admin: @demo),    "a demo session was started anyway"
  end
end
