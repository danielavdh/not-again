# frozen_string_literal: true

require "test_helper"

# A bare `render :action` renders in the REQUEST's format. These two actions
# have one template each, so anything but html or */* raised MissingTemplate —
# a 500 on the landing page of every upload-only admin, eight times in the week
# of 2026-10-12.
#
# share_receive arrives from the OS share sheet, so its Accept header is
# whatever the sharing app sent; upload_standalone is reached by redirect from
# every write guard, and a browser follows a redirect with the original Accept.
class ReceiptsFormatTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(admins(:upload_only)) }

  # Each of these raised before the fix. A page answering HTML to an odd Accept
  # is right; 500 never is.
  test "the standalone uploader answers HTML whatever is asked of it" do
    [ { "Accept" => "application/json" },
      { "Accept" => "*/*" },
      { "Accept" => "text/vnd.turbo-stream.html" },
      {} ].each do |headers|
      get upload_standalone_receipts_path, headers: headers
      assert_response :success, "Accept #{headers.inspect}"
      assert_equal "text/html", response.media_type, "Accept #{headers.inspect}"
    end
  end

  test "a format in the path does not 500 it either" do
    get "/en/receipts/upload_standalone.json"

    assert_response :success
    assert_equal "text/html", response.media_type
  end

  # The share target's whole audience is upload-only admins, and the write guard
  # was bouncing them to the uploader — losing the shared file, and 500ing on
  # the way because a browser follows a redirect with the original Accept.
  test "an upload-only admin can use the share target" do
    # POST: it is a Web Share Target (see the manifest).
    post share_receive_receipts_path, params: { title: "Lunch receipt" }

    assert_response :success
    assert_select "form"
  end

  test "the share target answers HTML whatever the sharing app sent" do
    post share_receive_receipts_path, params: { title: "Lunch receipt" },
         headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal "text/html", response.media_type
  end
end
