require "application_system_test_case"

# The transfer form holds the submit back to compare the two amounts with the
# published rate. Holding it back must never cost the user a second click.
class TransferSubmitTest < ApplicationSystemTestCase
  setup do
    sign_in_system(admins(:two))
    @from = accounts(:bank_gbp)
  end

  def fill_transfer(to:, sent:, received: nil)
    visit app_url("/en/accounts/#{@from.id}/new_transfer")
    assert_selector "#journal_entry_to_account_id.tomselected", visible: :all

    page.execute_script(<<~JS, to.id.to_s)
      document.getElementById('journal_entry_to_account_id').tomselect.setValue(arguments[0]);
    JS
    find("#journal_entry_transfer_amount_display").set(sent)
    find("#journal_entry_target_amount_display").set(received) if received
  end

  def assert_saved_by_one_click
    assert_difference -> { JournalEntry.count }, 1 do
      yield
      assert_current_path %r{/accounts/#{@from.id}/ledger}
    end
  end

  test "one click saves a same-currency transfer" do
    fill_transfer(to: accounts(:bank_gbp_two), sent: "12.34")
    assert_saved_by_one_click { click_button "Save Transfer" }
  end

  test "one click saves a cross-currency transfer with no published rate to compare" do
    fill_transfer(to: accounts(:bank_eur), sent: "100.00", received: "115.00")
    assert_saved_by_one_click { click_button "Save Transfer" }
  end

  test "a rate far off the published one asks once, and saving after yes takes no second click" do
    ExchangeRate.create!(from_currency: "GBP", to_currency: "EUR", source: "ecb", rate: 1.15,
                         effective_date: Date.current, valid_from: Date.current, valid_to: Date.current)
    fill_transfer(to: accounts(:bank_eur), sent: "100.00", received: "1150.00")

    assert_saved_by_one_click do
      accept_confirm { click_button "Save Transfer" }
    end
  end
end
