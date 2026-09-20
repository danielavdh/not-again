# frozen_string_literal: true

require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest

  # ==================== Full Access Admin Tests ====================

  class FullAccessAdminTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:two)  # full_access to family_biz(10) and daughter(04)
      @entity = entities(:family_biz)
      @linked = receipts(:linked_receipt)
      @unlinked = receipts(:unlinked_receipt)
      @posting = postings(:deposit_bank)
      sign_in_as(@admin)
    end

    # --- Index ---

    test "should get index" do
      get receipts_url(locale: :en)
      assert_response :success
    end

    test "index renders the bulk-download UI (§8)" do
      get receipts_url(locale: :en)
      assert_select "input[data-action='select-all-receipts']", 1
      assert_select "input[data-role='receipt-checkbox']", minimum: 1
      assert_select "form[action=?]", download_selected_receipts_path

      # The submit button lives in the header row, outside the form's own DOM
      # subtree, joined to it by id — the same reasoning as the checkboxes,
      # since it sits in the SAME cell as the select-all checkbox, which is
      # itself outside the form.
      assert_select "th.receipt-select-col button[form='download-selected-form'][type='submit']" do |buttons|
        use = buttons.first.at_css("use")
        assert use, "the button should contain a <use> referencing the download icon"
        assert_equal "#te_download", use.attribute("href").value
      end
    end

    # The bug this is named after: the download-selected form wrapped the whole
    # table, and several rows already carry their own button_to — each its OWN
    # <form>. Forms cannot nest, and assert_select against raw markup cannot
    # catch that because it is not a DOM parser. Nokogiri, parsing the response
    # the way a browser would, can.
    test "no form is nested inside another form anywhere on the index page" do
      get receipts_url(locale: :en)
      doc = Nokogiri::HTML::Document.parse(response.body)
      doc.css("form").each do |form|
        assert_empty form.css("form"), "a <form> must never contain another <form>: #{form.to_html[0, 200]}"
      end
    end

    # Each receipt's checkbox has to reach the download form via the HTML5
    # form="..." attribute specifically BECAUSE it cannot be nested inside it.
    test "receipt checkboxes are associated with the download form via form=, not nesting" do
      get receipts_url(locale: :en)
      doc = Nokogiri::HTML::Document.parse(response.body)
      download_form = doc.at_css("form[action='#{download_selected_receipts_path}']")
      assert download_form, "the download-selected form must exist"
      form_id = download_form["id"]
      assert form_id.present?, "the download form needs an id for checkboxes to reference"

      checkboxes = doc.css("input[data-role='receipt-checkbox']")
      assert checkboxes.any?
      checkboxes.each do |box|
        assert_equal form_id, box["form"],
          "each receipt checkbox must set form=\"#{form_id}\", not sit inside the form's own DOM subtree"
      end
    end

    test "download redirects to receipt url with valid sgid" do
      sgid = @linked.signed_id(expires_in: 30.days, purpose: :download)
      get download_receipt_url(@linked, locale: :en, sgid: sgid)
      assert_response :redirect
    end

    test "download returns 404 with invalid sgid" do
      get download_receipt_url(@linked, locale: :en, sgid: "invalid")
      assert_response :not_found
    end

    # --- download_selected (§8 bulk export) ---

    test "download_selected zips exactly the ticked receipts" do
      first  = create_real_receipt!("First")
      second = create_real_receipt!("Second")

      post download_selected_receipts_url(locale: :en),
        params: { receipt_ids: [ first.id, second.id ] }

      assert_response :success
      assert_equal "application/zip", response.content_type
      assert_equal [ "#{first.id}-#{first.display_filename}", "#{second.id}-#{second.display_filename}" ].sort,
        zip_entry_names(response.body).sort
    end

    test "download_selected ignores an id from a receipt this admin cannot access" do
      mine    = create_real_receipt!("Mine")
      foreign = receipts(:personal_receipt) # entity 01 — not @admin's

      post download_selected_receipts_url(locale: :en),
        params: { receipt_ids: [ mine.id, foreign.id ] }

      assert_response :success
      assert_equal [ "#{mine.id}-#{mine.display_filename}" ], zip_entry_names(response.body)
    end

    test "download_selected with nothing ticked redirects instead of building an empty zip" do
      post download_selected_receipts_url(locale: :en), params: { receipt_ids: [] }
      assert_redirected_to receipts_path(locale: :en)
    end

    # One receipt whose stored file the bucket has lost must not 500 the whole
    # download — the rest come through and the zip names the casualty.
    test "download_selected skips a receipt whose file is missing, lists it, still returns the rest" do
      ok      = create_real_receipt!("Intact")
      broken  = create_real_receipt!("Lost")
      broken.scan.delete # file gone, DB row still points at it

      post download_selected_receipts_url(locale: :en),
        params: { receipt_ids: [ ok.id, broken.id ] }

      assert_response :success
      names = zip_entry_names(response.body)
      assert_includes names, "#{ok.id}-#{ok.display_filename}"
      assert_includes names, "_MISSING.txt"
      assert_not_includes names, "#{broken.id}-#{broken.display_filename}"
    end

    def create_real_receipt!(title)
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      post receipts_url(locale: :en), params: {
        receipt: { title: title, receipt_date: Date.current.to_s, entity_id: @entity.id, scan: scan_file }
      }
      Receipt.find_by!(title: title)
    end

    def zip_entry_names(zip_bytes)
      names = []
      Zip::InputStream.open(StringIO.new(zip_bytes)) do |zis|
        while (entry = zis.get_next_entry)
          names << entry.name
        end
      end
      names
    end

    test "download returns 404 when no sgid" do
      get download_receipt_url(@linked, locale: :en)
      assert_response :not_found
    end

    test "download works without being logged in" do
      sign_out
      sgid = @linked.signed_id(expires_in: 30.days, purpose: :download)
      get download_receipt_url(@linked, locale: :en, sgid: sgid)
      assert_response :redirect
    end

    test "index filters by entity" do
      get receipts_url(locale: :en), params: { entity_id: @entity.id }
      assert_response :success
    end

    test "index filters unlinked" do
      get receipts_url(locale: :en), params: { filter: "unlinked" }
      assert_response :success
    end

    test "index filters linked" do
      get receipts_url(locale: :en), params: { filter: "linked" }
      assert_response :success
    end

    test "index filters by date range" do
      get receipts_url(locale: :en), params: {
        start_date: (Date.current - 30.days).to_s,
        end_date: Date.current.to_s
      }
      assert_response :success
    end

    # --- Show ---

    test "should show receipt" do
      get receipt_url(@linked, locale: :en)
      assert_response :success
    end

    test "show returns json" do
      get receipt_url(@linked, locale: :en, format: :json)
      assert_response :success
      json = JSON.parse(response.body)
      assert_equal @linked.id, json["id"]
      assert_equal @linked.title, json["title"]
    end

    test "cannot show receipt from another entity" do
      personal_receipt = receipts(:personal_receipt)  # entity 01, admin two has no access
      get receipt_url(personal_receipt, locale: :en)
      assert_response :not_found
    end

    # --- New ---

    test "should get new" do
      get new_receipt_url(locale: :en)
      assert_response :success
    end

    test "new with posting_id pre-fills posting" do
      get new_receipt_url(locale: :en), params: { posting_id: @posting.id }
      assert_response :success
    end

    # --- Create ---

    test "should create receipt" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      assert_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "New Receipt",
            receipt_date: Date.current.to_s,
            entity_id: @entity.id,
            scan: scan_file
          }
        }
      end
      assert_redirected_to receipts_path(locale: :en)
    end

    test "create receipt sets uploaded_by to current admin" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      post receipts_url(locale: :en), params: {
        receipt: {
          title: "Tracked Upload",
          receipt_date: Date.current.to_s,
          entity_id: @entity.id,
          scan: scan_file
        }
      }
      receipt = Receipt.find_by(title: "Tracked Upload")
      assert_equal @admin.id, receipt.uploaded_by_id
    end

    test "create receipt via json" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      post receipts_url(locale: :en, format: :json), params: {
        receipt: {
          title: "JSON Receipt",
          receipt_date: Date.current.to_s,
          entity_id: @entity.id,
          scan: scan_file
        }
      }
      assert_response :created
      json = JSON.parse(response.body)
      assert_equal "JSON Receipt", json["title"]
    end

    test "create fails without title" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      assert_no_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "",
            receipt_date: Date.current.to_s,
            entity_id: @entity.id,
            scan: scan_file
          }
        }
      end
      assert_response :unprocessable_entity
    end

    test "create fails without scan" do
      assert_no_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "No Scan",
            receipt_date: Date.current.to_s,
            entity_id: @entity.id
          }
        }
      end
      assert_response :unprocessable_entity
    end

    test "create fails via json returns errors" do
      assert_no_difference("Receipt.count") do
        post receipts_url(locale: :en, format: :json), params: {
          receipt: {
            title: "",
            receipt_date: Date.current.to_s,
            entity_id: @entity.id
          }
        }
      end
      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      assert json["errors"].present?
    end

    # --- Edit / Update ---

    test "should get edit" do
      get edit_receipt_url(@unlinked, locale: :en)
      assert_response :success
    end

    test "should update receipt" do
      patch receipt_url(@unlinked, locale: :en), params: {
        receipt: { title: "Updated Title" }
      }
      assert_redirected_to receipts_path(locale: :en)
      @unlinked.reload
      assert_equal "Updated Title", @unlinked.title
    end

    test "update via json" do
      patch receipt_url(@unlinked, locale: :en, format: :json), params: {
        receipt: { title: "JSON Updated" }
      }
      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "JSON Updated", json["title"]
    end

    test "update fails with invalid data" do
      patch receipt_url(@unlinked, locale: :en), params: {
        receipt: { title: "" }
      }
      assert_response :unprocessable_entity
    end

    test "update fails via json returns errors" do
      patch receipt_url(@unlinked, locale: :en, format: :json), params: {
        receipt: { title: "" }
      }
      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      assert json["errors"].present?
    end

    # --- Destroy ---

    test "should destroy receipt" do
      assert_difference("Receipt.count", -1) do
        delete receipt_url(@unlinked, locale: :en)
      end
      assert_redirected_to receipts_path(locale: :en)
    end

    test "destroy via json" do
      assert_difference("Receipt.count", -1) do
        delete receipt_url(@unlinked, locale: :en, format: :json)
      end
      assert_response :no_content
    end

    # --- Link / Unlink ---

    test "should link receipt to posting" do
      post link_receipt_url(@unlinked, locale: :en, format: :json), params: {
        posting_id: @posting.id
      }
      assert_response :success
      @unlinked.reload
      assert_equal @posting.id, @unlinked.posting_id
    end

    test "should unlink receipt from posting" do
      post unlink_receipt_url(@linked, locale: :en, format: :json)
      assert_response :success
      @linked.reload
      assert_nil @linked.posting_id
    end

    test "unlink via html redirects back" do
      post unlink_receipt_url(@linked, locale: :en)
      assert_response :redirect
      @linked.reload
      assert_nil @linked.posting_id
    end

    # --- for_posting (JSON) ---

    test "for_posting returns receipts for a posting" do
      get for_posting_receipts_url(posting_id: @posting.id, locale: :en, format: :json)
      assert_response :success
      json = JSON.parse(response.body)
      assert_kind_of Array, json
    end

    # --- unlinked (JSON) ---

    test "unlinked returns unlinked receipts" do
      get unlinked_receipts_url(locale: :en, format: :json)
      assert_response :success
      json = JSON.parse(response.body)
      assert_kind_of Array, json
    end

    # The modal fetches a partial rather than building rows from JSON with
    # template strings, the way the add-account modal does.

    test "for_posting renders the picker list as HTML" do
      get for_posting_receipts_url(posting_id: @posting.id, locale: :en),
        headers: { "Accept" => "text/html" }
      assert_response :success
      assert_select "div.receipt-picker-item[data-action=?]", "preview-receipt"
    end

    test "unlinked renders the picker list as HTML in pick mode" do
      get unlinked_receipts_url(locale: :en), headers: { "Accept" => "text/html" }
      assert_response :success
      assert_select "div.receipt-picker-item[data-action=?]", "pick-receipt"
    end

    test "an empty picker list says so rather than rendering nothing" do
      Receipt.update_all(posting_id: @posting.id)
      get unlinked_receipts_url(locale: :en), headers: { "Accept" => "text/html" }
      assert_response :success
      assert_select "p.empty"
    end

    # The reason this moved out of JavaScript. A title is user input, and it
    # used
    # to be interpolated straight into innerHTML.
    test "a receipt title containing markup is escaped, not rendered" do
      @unlinked.update!(title: "<img src=x onerror=alert(1)>")
      get unlinked_receipts_url(locale: :en), headers: { "Accept" => "text/html" }
      assert_response :success
      assert_no_match(/<img src=x onerror/, response.body)
      assert_match(/&lt;img src=x onerror/, response.body)
    end

  end

  # ==================== Upload-Only Admin Tests ====================

  class UploadOnlyAdminTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:upload_only)  # upload_receipts access to personal(01)
      @entity = entities(:personal)
      @own_receipt = receipts(:uploaded_receipt)
      sign_in_as(@admin)
    end

    test "upload_standalone renders upload page" do
      get upload_standalone_receipts_url(locale: :en)
      assert_response :success
    end

    test "can create receipt" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      assert_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Upload Only Receipt",
            receipt_date: Date.current.to_s,
            entity_id: @entity.id,
            scan: scan_file
          }
        }
      end
    end

    test "create failure re-renders upload_standalone" do
      assert_no_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "",
            receipt_date: Date.current.to_s,
            entity_id: @entity.id
          }
        }
      end
      assert_response :unprocessable_entity
    end

    test "can delete own unlinked receipt" do
      assert_difference("Receipt.count", -1) do
        delete delete_own_receipt_url(@own_receipt, locale: :en)
      end
    end

    test "cannot delete receipt uploaded by someone else" do
      other_receipt = receipts(:personal_receipt)
      delete delete_own_receipt_url(other_receipt, locale: :en)
      assert_response :not_found
    end

    test "accounts index redirects to upload_standalone" do
      get accounts_url(locale: :en)
      assert_redirected_to upload_standalone_receipts_path
    end
  end

  # ==================== Read-Only Admin Tests ====================

  class ReadOnlyAdminTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:read_only)  # read_only access to personal(01)
      @entity = entities(:personal)
      @receipt = receipts(:personal_receipt)
      sign_in_as(@admin)
    end

    test "can view index" do
      get receipts_url(locale: :en)
      assert_response :success
    end

    test "can view show" do
      get receipt_url(@receipt, locale: :en)
      assert_response :success
    end

    test "cannot create receipt (no receipt access)" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      post receipts_url(locale: :en), params: {
        receipt: {
          title: "Should Fail",
          receipt_date: Date.current.to_s,
          entity_id: @entity.id,
          scan: scan_file
        }
      }
      # read_only has no receipt upload access, redirected
      assert_response :redirect
    end

    test "cannot access new receipt form" do
      get new_receipt_url(locale: :en)
      assert_response :redirect
    end

    test "write access blocked for non-GET requests" do
      post accounts_url(locale: :en), params: {
        account: { code: "101999", name: "Hack", account_type: :asset }
      }
      assert_response :redirect
    end

  end

  # ==================== Sudo Admin Tests ====================

  class SudoAdminTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:sudo)
      @receipt = receipts(:linked_receipt)
      sign_in_as(@admin)
    end

    test "sudo can view all receipts" do
      get receipts_url(locale: :en)
      assert_response :success
    end

    test "sudo can show any receipt" do
      get receipt_url(@receipt, locale: :en)
      assert_response :success
    end

    test "sudo can create receipt for any entity" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      assert_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Sudo Receipt",
            receipt_date: Date.current.to_s,
            entity_id: entities(:standalone).id,
            scan: scan_file
          }
        }
      end
    end

    test "sudo unlinked endpoint returns all unlinked" do
      get unlinked_receipts_url(locale: :en, format: :json)
      assert_response :success
      json = JSON.parse(response.body)
      assert_kind_of Array, json
    end
  end

  # ==================== Unauthenticated Tests ====================

  class UnauthenticatedTests < ActionDispatch::IntegrationTest
    setup do
    end

    test "unauthenticated cannot access receipts index" do
      get receipts_url(locale: :en)
      assert_response :redirect
    end

    test "unauthenticated cannot create receipt" do
      post receipts_url(locale: :en), params: {
        receipt: { title: "Hack" }
      }
      assert_response :redirect
    end
  end

  # ==================== Share Receive Tests ====================

  class ShareReceiveTests < ActionDispatch::IntegrationTest
    setup do
      @admin = admins(:two)
      sign_in_as(@admin)
    end

    test "share_receive renders form with pre-filled title" do
      post share_receive_receipts_url(locale: :en), params: {
        title: "Shared Document"
      }
      assert_response :success
    end

    test "share_receive uses text param as fallback title" do
      post share_receive_receipts_url(locale: :en), params: {
        text: "From share intent"
      }
      assert_response :success
    end

    test "share_receive defaults title when no params" do
      post share_receive_receipts_url(locale: :en)
      assert_response :success
    end
  end

  # The entity dropdown is filtered and #link resolves postings through
  # accessible_postings, but #create and #update take entity_id and posting_id
  # straight from the form. Hand-editing either one used to put a receipt into
  # somebody else's books.

  class ForgedTargetTests < ActionDispatch::IntegrationTest
    setup do
      @admin       = admins(:two)            # full_access on family_biz(10) + daughter(04)
      @own_entity  = entities(:family_biz)
      @foreign     = entities(:personal) # 01 — admin one's, not theirs
      @own_receipt = receipts(:unlinked_receipt)
      sign_in_as(@admin)
    end

    def scan_file
      fixture_file_upload("test_receipt.jpg", "image/jpeg")
    end

    test "cannot create a receipt in an entity they do not hold" do
      assert_no_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Injected",
            receipt_date: Date.current.to_s,
            entity_id: @foreign.id,
            scan: scan_file
          }
        }
      end
      assert_redirected_to receipts_path(locale: :en)
      assert_equal I18n.t("access.no_receipt_upload"), flash[:alert]
    end

    test "forged entity is refused over json too" do
      post receipts_url(locale: :en, format: :json), params: {
        receipt: {
          title: "Injected",
          receipt_date: Date.current.to_s,
          entity_id: @foreign.id,
          scan: scan_file
        }
      }
      assert_response :forbidden
    end

    test "cannot move an existing receipt into an entity they do not hold" do
      original = @own_receipt.entity_id
      patch receipt_url(@own_receipt, locale: :en), params: {
        receipt: { entity_id: @foreign.id }
      }
      assert_redirected_to receipts_path(locale: :en)
      assert_equal original, @own_receipt.reload.entity_id
    end

    test "the legitimate entity still goes through" do
      assert_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Mine",
            receipt_date: Date.current.to_s,
            entity_id: @own_entity.id,
            scan: scan_file
          }
        }
      end
      assert_redirected_to receipts_path(locale: :en)
    end
  end

  # An upload-receipts co-admin is the narrowest role there is: they may put a
  # receipt into the one entity they were invited to, and attach it to nothing.
  class UploadOnlyForgedTargetTests < ActionDispatch::IntegrationTest
    setup do
      @admin           = admins(:upload_only) # upload_receipts on personal(01)
      @own_entity      = entities(:personal)
      @foreign         = entities(:family_biz)
      @foreign_posting = postings(:deposit_bank) # account 110001 → entity 10
      sign_in_as(@admin)
    end

    def scan_file
      fixture_file_upload("test_receipt.jpg", "image/jpeg")
    end

    test "cannot upload into another entity" do
      assert_no_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Injected",
            receipt_date: Date.current.to_s,
            entity_id: @foreign.id,
            scan: scan_file
          }
        }
      end
    end

    test "cannot attach a receipt to a posting they cannot see" do
      assert_no_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Injected",
            receipt_date: Date.current.to_s,
            entity_id: @own_entity.id,
            posting_id: @foreign_posting.id,
            scan: scan_file
          }
        }
      end
    end

    test "their own entity still works" do
      assert_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Mine",
            receipt_date: Date.current.to_s,
            entity_id: @own_entity.id,
            scan: scan_file
          }
        }
      end
    end
  end

  # The entity picker must offer only what the server will accept.
  # authorize_receipt_target enforces upload_entity_ids on create and update,
  # but the new/edit views and the upload modal built their own, WIDER list of
  # every accessible entity — so a mixed-level admin was shown entities the
  # server then refused. The picker and the guard have to agree.
  class ReceiptEntityPickerTests < ActionDispatch::IntegrationTest
    setup do
      # full_access on family_biz (10), read_only on personal (01)
      @admin = admins(:mixed)
      sign_in_as(@admin)
    end

    # This admin can READ two entities but may only upload to one, so the form
    # is down to a single choice — and _form renders a hidden field rather than
    # a one-option dropdown at that point. The read-only entity must appear
    # nowhere in the markup either way.
    test "the new-receipt form offers only the entity the admin may upload to" do
      get new_receipt_url(locale: :en)
      assert_response :success

      assert_select "input[type=hidden][name=?][value=?]", "receipt[entity_id]",
                    entities(:family_biz).id.to_s
      assert_select "option[value=?]", entities(:personal).id.to_s, count: 0
      assert_select "input[name=?][value=?]", "receipt[entity_id]",
                    entities(:personal).id.to_s, count: 0
    end

    test "the server refuses the read-only entity the picker no longer offers" do
      scan_file = fixture_file_upload("test_receipt.jpg", "image/jpeg")
      assert_no_difference("Receipt.count") do
        post receipts_url(locale: :en), params: {
          receipt: {
            title: "Should be refused",
            receipt_date: Date.current.to_s,
            entity_id: entities(:personal).id,
            scan: scan_file
          }
        }
      end
    end
  end
end
