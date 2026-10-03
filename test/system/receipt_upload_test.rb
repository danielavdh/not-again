require "application_system_test_case"

# Uploading a receipt to a posting that had none must make the "view receipts"
# button appear on that posting's widget, there and then.
#
# The claim is about the page the admin is looking at, not about the upload: the
# receipt saves either way. What breaks is refreshPostingReceipts, which asks
# receipts#for_posting for its answer — and that action serves HTML to the
# picker modal and JSON here, so a caller that forgets to say which gets a
# partial where it expected an array and dies before touching the DOM. Nothing
# below the browser can catch that.
class ReceiptUploadTest < ApplicationSystemTestCase
  setup do
    sign_in_system(admins(:two))
  end

  # multi_posting_deposit: bank_gbp debit 95.00, income 100.00, fees debit 5.00.
  # The fees posting carries no receipt in the fixtures.
  def fees_widget
    find(".receipt-posting-widget[data-posting-id='#{postings(:multi_deposit_fees).id}']")
  end

  def visit_the_entry
    visit app_url(
      "/en/accounts/#{accounts(:bank_gbp).id}/edit_deposit" \
      "?journal_entry_id=#{journal_entries(:multi_posting_deposit).id}"
    )
  end

  test "uploading a receipt to a posting reveals that posting's view-receipts button" do
    visit_the_entry

    assert_no_selector ".receipt-posting-widget[data-posting-id='#{postings(:multi_deposit_fees).id}'] " \
                       "[data-action='view-posting-receipts']"

    fees_widget.find("[data-action='upload-receipt-for-posting']").click

    within "#receipt-upload-modal" do
      fill_in "receipt_title", with: "Bank charges April"
      # Two file inputs share the id — "choose a file" and "take a photo".
      find("input[data-receipt-file]", visible: :all)
        .set(Rails.root.join("test/fixtures/files/test_receipt.jpg"))
      find("button[type='submit']").click
    end

    # No reload: the button is put there by refreshPostingReceipts.
    assert_selector ".receipt-posting-widget[data-posting-id='#{postings(:multi_deposit_fees).id}'] " \
                    "[data-action='view-posting-receipts']"
    assert_equal 1, postings(:multi_deposit_fees).receipts.count
  end
end
