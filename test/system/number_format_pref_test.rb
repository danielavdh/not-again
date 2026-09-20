require "application_system_test_case"

# The number-format picker on the profile page: a choice of how grouped money is
# written — thousands and decimal separator, plus symbol side — overriding the
# UI language. Once set, EVERY amount follows it, including the live on-blur
# reformat in an entry form, which reads the same #number-format-config the
# server wrote.
class NumberFormatPrefTest < ApplicationSystemTestCase
  setup do
    @admin = admins(:two) # full access, English UI
    sign_in_system(@admin)
  end

  test "picking a format reformats a freshly typed amount to match, without a reload" do
    visit app_url("/en/journal_entries/new")

    # English default: dot decimal.
    field = first("input.posting-amount")
    field.set("1234.5")
    field.native.send_keys(:tab)
    assert_equal "1,234.50", first("input.posting-amount").value

    # Choose the European shape on the profile (the select auto-submits).
    visit app_url("/en/admins/#{@admin.id}")
    select "1.234,56 ¤", from: "admin_preferred_number_format"
    assert_current_path %r{/admins/#{@admin.id}}   # redirected back after save
    assert_equal "de", @admin.reload.preferred_number_format

    # Same input, now written the European way.
    visit app_url("/en/journal_entries/new")
    field = first("input.posting-amount")
    field.set("1234.5")
    field.native.send_keys(:tab)
    assert_equal "1.234,50", first("input.posting-amount").value
  end

  test "clearing the choice falls back to the UI language" do
    @admin.update!(preferred_number_format: "ch")
    visit app_url("/en/admins/#{@admin.id}")
    find("#admin_preferred_number_format option[value='']").select_option # the "(automatic)" blank
    assert_nil @admin.reload.preferred_number_format
  end
end
