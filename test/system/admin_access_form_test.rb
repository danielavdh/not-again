require "application_system_test_case"

# One page, two jobs, and the email address picks which. Typing an address that
# already belongs to an admin must turn the page into "change what they can
# reach" — their current full access ticked, and no username or password asked
# for. Typing a new address must turn it back into "create a person".
#
# The switch happens in the browser: index.js fetches the entity-access block
# from the server and swaps it in. Nothing below the browser can tell whether
# that worked.
class AdminAccessFormTest < ApplicationSystemTestCase
  setup do
    sign_in_system(admins(:sudo))
  end

  def box_for(entity)
    find("#entity_#{entity.id}", visible: :all)
  end

  def enter_email(address)
    fill_in "admin_email_address", with: address
    find("h1").click # focusout, which is what index.js listens for
  end

  # admins(:mixed) holds full access to family_biz and read_only to personal.
  test "an existing admin's email brings back their current access, ticked" do
    visit app_url("/en/admins/new")

    assert_no_selector "#entity_#{entities(:family_biz).id}:checked"

    enter_email(admins(:mixed).email_address)

    assert_selector "#entity-access-fields[data-existing='true']"
    assert box_for(entities(:family_biz)).checked?,
           "the entity they already have full access to must come back ticked"
    # Held at a lower level: no box at all, so an untick cannot destroy it.
    assert_no_selector "#entity_#{entities(:personal).id}", visible: :all
    # An existing admin needs no username or password.
    assert_no_selector "#new-person-fields[open]"
  end

  test "an unknown email asks for a username and password instead" do
    visit app_url("/en/admins/new")

    enter_email("nobody_here_at_all@example.com")

    assert_selector "#entity-access-fields[data-existing='false']"
    assert_selector "#new-person-fields[open]"
    # A new person starts with nothing ticked.
    assert_no_selector "#entity_#{entities(:family_biz).id}:checked"
  end
end
