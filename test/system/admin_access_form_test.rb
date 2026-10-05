require "application_system_test_case"

# The grant page's ticks are the current access of whoever the identifier
# belongs to, fetched as it is typed. Nothing on the page appears or disappears
# while you type — it has one job and no password — so there is no state that
# can be timed wrongly against the lookup.
#
# The fetch and the swap happen in the browser, so nothing below it can tell
# whether they worked.
class AdminAccessFormTest < ApplicationSystemTestCase
  setup do
    sign_in_system(admins(:sudo))
  end

  def box_for(entity)
    find("#entity_#{entity.id}", visible: :all)
  end

  # Typing is the whole gesture — there is nothing to tab to and nothing to
  # click away onto. Capybara's own waiting covers the debounce.
  def enter_email(address)
    fill_in "admin_email_address", with: address
  end

  # admins(:mixed) holds full access to family_biz and read_only to personal.
  test "an existing admin's identifier brings back their current access, ticked" do
    visit app_url("/en/admins/grant_access")

    assert_no_selector "#entity_#{entities(:family_biz).id}:checked"

    enter_email(admins(:mixed).email_address)

    assert_selector "#entity-access-fields[data-existing='true']"
    assert box_for(entities(:family_biz)).checked?,
           "the entity they already have full access to must come back ticked"
    # Sudo may raise a read-only grant to full access, so the box is drawn —
    # but unticked, because they do not hold full access to it yet.
    assert_not box_for(entities(:personal)).checked?,
               "a read-only grant must not look like full access"
  end

  # The page asks for an address AND a username, because creating someone needs
  # both — so for a person who already exists it fills theirs in rather than
  # expecting the sender to know it. Without this the two fields disagree and
  # the submission is refused.
  test "finding someone by address fills their username in" do
    visit app_url("/en/admins/grant_access")

    enter_email(admins(:mixed).email_address)

    assert_selector "#entity-access-fields[data-existing='true']"
    assert_equal admins(:mixed).username, find("#admin_username").value
  end

  # Typing the address, then starting on a username before the lookup lands,
  # would otherwise leave a half-typed name that the save then refuses. Once the
  # address identifies somebody, THEIR username is the only value that can be
  # submitted, so it replaces whatever is there.
  test "a username left over from typing is replaced by the right one" do
    visit app_url("/en/admins/grant_access")

    fill_in "admin_username", with: "dan"
    enter_email(admins(:mixed).email_address)

    assert_selector "#entity-access-fields[data-existing='true']"
    assert_equal admins(:mixed).username, find("#admin_username").value
  end

  # Creating somebody is a bigger step than changing their access, and a typo in
  # an address looks exactly like a new colleague — so submitting says what is
  # about to happen. Asked in the browser, before the request, so it costs one
  # round trip rather than two; the server still requires the consent it sets.
  test "submitting a new person says so first, and then creates them in one go" do
    visit app_url("/en/admins/grant_access")

    enter_email("brand_new_colleague@example.com")
    assert_selector "#entity-access-fields[data-create-prompt*='brand_new_colleague@example.com']"
    fill_in "admin_username", with: "brand_new_colleague"
    check "entity_#{entities(:standalone).id}"

    assert_difference -> { Admin.count } do
      accept_confirm { click_on I18n.t("admins.form.grant_submit") }
      assert_no_selector "#entity-access-fields"  # left the page: it saved
    end

    created = Admin.find_by(email_address: "brand_new_colleague@example.com")
    assert created.admin_entities.with_full_access.exists?(entity_id: entities(:standalone).id)
  end

  # Nobody should be asked to confirm something the form is going to refuse.
  test "nothing is asked while the form could not succeed anyway" do
    visit app_url("/en/admins/grant_access")

    enter_email("brand_new_colleague@example.com")
    assert_selector "#entity-access-fields[data-create-prompt*='brand_new_colleague@example.com']"
    fill_in "admin_username", with: "brand_new_colleague"
    # No business ticked, so the submission cannot succeed.

    assert_no_difference -> { Admin.count } do
      click_on I18n.t("admins.form.grant_submit")
      assert_selector "div.field_with_errors"
    end
  end

  # Granting changes somebody's access, never their name. So for a person who
  # already exists the username is filled in and locked — a field that cannot be
  # acted on must not invite typing, which is what let a wrong one sit there and
  # be silently ignored.
  test "the username is locked while an existing person is the subject, and freed again" do
    visit app_url("/en/admins/grant_access")

    assert_not find("#admin_username").readonly?, "a new person's username is theirs to be given"

    enter_email(admins(:mixed).email_address)
    assert_selector "#entity-access-fields[data-existing='true']"
    assert find("#admin_username").readonly?, "it is not this form's business to rename anybody"

    # Clearing the address means nobody is named, so the field is a new
    # person's again.
    enter_email("")
    assert_selector "#entity-access-fields[data-existing='false']"
    assert_not find("#admin_username").readonly?
  end

  # The address is the only identity. A username identifies nobody — otherwise
  # clearing the email would quietly move the form from "create someone" to
  # "change this person's access", with nothing said and nobody asked.
  test "a username alone identifies nobody" do
    visit app_url("/en/admins/grant_access")

    fill_in "admin_username", with: admins(:mixed).username

    assert_selector "#entity-access-fields[data-existing='false']"
    assert_no_selector "#entity_#{entities(:family_biz).id}:checked"
  end

  test "an unknown identifier leaves every box clear, and asks for no password" do
    visit app_url("/en/admins/grant_access")

    enter_email("nobody_here_at_all@example.com")

    assert_selector "#entity-access-fields[data-existing='false']"
    # A new person starts with nothing.
    assert_no_selector "#entity_#{entities(:family_biz).id}:checked"
    # Generated server-side and replaced at their first login, so there is
    # nothing to type here and nothing to reveal.
    assert_no_selector "input[type='password']", visible: :all
  end
end
