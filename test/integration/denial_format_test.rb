require "test_helper"

# A refusal must answer in the format that was asked for.
#
# Denying by redirect is right for a person and wrong for JavaScript: fetch()
# FOLLOWS a redirect, so the denial arrives as a GET of an HTML page. Where that
# page cannot render JSON the browser gets a 406; where it can, the script gets
# markup and dies on .json(). The receipt uploader is where it surfaced — POST
# /receipts, denied, followed to the receipts index, 406, "Unexpected token
# '<'".
class DenialFormatTest < ActionDispatch::IntegrationTest
  setup { sign_in_as admins(:read_only) }

  test "a JSON write refusal is a 403 with JSON in it, not a redirect" do
    post receipts_path(format: :json, locale: :en),
         params: { receipt: { entity_id: entities(:personal).id } }

    assert_response :forbidden
    assert_equal "application/json", response.media_type
    assert_nothing_raised { JSON.parse(response.body) }
  end

  test "the same refusal still redirects a person" do
    post receipts_path(locale: :en), params: { receipt: { entity_id: entities(:personal).id } }

    assert_response :redirect
    assert_equal I18n.t("access.no_receipt_upload"), flash[:alert]
  end

  # deny_write guards every per-resource write in the app, so this is the one
  # that mattered beyond receipts.
  test "a JSON refusal from the general write guard is also JSON" do
    account = accounts(:boss_bank)
    was     = account.name

    patch account_path(account, format: :json, locale: :en),
          params: { account: { name: "Renamed by a reader" } }

    assert_response :forbidden
    assert_nothing_raised { JSON.parse(response.body) }
    assert_equal was, account.reload.name, "a refused write must not have landed"
  end
end
