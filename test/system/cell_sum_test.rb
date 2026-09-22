require "application_system_test_case"

# ⌘-click adds an amount to a running sum, Shift-click adds a range. A plain
# click must keep meaning what it meant before: in an entry form, "edit this
# amount". A selection never crosses a column, so the sum is one currency.
class CellSumTest < ApplicationSystemTestCase
  setup do
    sign_in_system(admins(:two))
  end

  # multi_posting_deposit: bank debit 95.00, income credit 100.00, fees debit 5.00, all GBP
  def debit_cells
    all("#postings-table tbody tr td:nth-child(5)").reject { |td| td.text.strip.empty? }
  end

  def credit_cells
    all("#postings-table tbody tr td:nth-child(6)").reject { |td| td.text.strip.empty? }
  end

  test "⌘-clicking two amounts in one column shows their sum in that column's currency" do
    visit app_url("/en/journal_entries/#{journal_entries(:multi_posting_deposit).id}")
    assert_no_selector "#cell-sum", visible: true

    debit_cells.each { |td| td.click(:meta) }

    assert_selector "#cell-sum", visible: true, text: CurrencyConfig.format_cents(10_000, "GBP", locale: :en)
    assert_selector "#postings-table td[aria-selected='true']", count: 2
  end

  # formatCentsWithCurrency mirrors CurrencyConfig#format_cents; "de" puts the
  # symbol after the number, with a non-breaking space.
  test "the sum follows the admin's number format, symbol position included" do
    admins(:two).update!(preferred_number_format: "de")
    visit app_url("/en/journal_entries/#{journal_entries(:multi_posting_deposit).id}")

    debit_cells.each { |td| td.click(:meta) }

    assert_selector "#cell-sum", visible: true
    assert_equal "100,00\u00A0£", page.evaluate_script("document.querySelector('#cell-sum [data-sum-total]').textContent")
  end

  test "Shift-click takes the range and skips empty cells" do
    visit app_url("/en/journal_entries/#{journal_entries(:multi_posting_deposit).id}")

    first_debit, last_debit = debit_cells.first, debit_cells.last
    first_debit.click(:meta)
    last_debit.click(:shift)

    assert_selector "#postings-table td[aria-selected='true']", count: 2
    assert_selector "#cell-sum", visible: true, text: CurrencyConfig.format_cents(10_000, "GBP", locale: :en)
  end

  test "a plain click then Shift-click selects the range, like a spreadsheet" do
    visit app_url("/en/journal_entries/#{journal_entries(:multi_posting_deposit).id}")

    debit_cells.first.click
    assert_selector "#postings-table td[aria-selected='true']", count: 1
    assert_no_selector "#cell-sum", visible: true

    debit_cells.last.click(:shift)
    assert_selector "#postings-table td[aria-selected='true']", count: 2
    assert_selector "#cell-sum", visible: true, text: CurrencyConfig.format_cents(10_000, "GBP", locale: :en)
  end

  test "an amount from another column starts a new selection instead of adding" do
    visit app_url("/en/journal_entries/#{journal_entries(:multi_posting_deposit).id}")

    debit_cells.each { |td| td.click(:meta) }
    credit_cells.first.click(:meta)

    assert_selector "#postings-table td[aria-selected='true']", count: 1
    assert_no_selector "#cell-sum", visible: true
  end

  test "Escape clears the selection and does not navigate away" do
    path = "/en/journal_entries/#{journal_entries(:multi_posting_deposit).id}"
    visit app_url(path)
    debit_cells.each { |td| td.click(:meta) }

    find("body").send_keys(:escape)

    assert_no_selector "#postings-table td[aria-selected]"
    assert_current_path path
  end

  # the stylesheet's hook for the cursor: amounts under a data-sum header, and nothing else
  test "exactly the non-empty cells of summable columns are marked data-summable" do
    visit app_url("/en/journal_entries/#{journal_entries(:multi_posting_deposit).id}")

    assert_selector "#postings-table td[data-summable]", count: 3 # 95.00 + 5.00 debit, 100.00 credit
    (debit_cells + credit_cells).each { |td| assert_equal "", td["data-summable"] }
    assert_no_selector "#postings-table td:first-child[data-summable]"
  end

  test "columns without a data-sum header are not summable" do
    visit app_url("/en/journal_entries/#{journal_entries(:multi_posting_deposit).id}")

    all("#postings-table tbody tr td:first-child").first(2).each { |td| td.click(:meta) }

    assert_no_selector "#postings-table td[aria-selected]"
  end

  test "in an entry form, ⌘-click sums without entering the field; a plain click still edits" do
    visit app_url("/en/journal_entries/new")
    amounts = all("input.posting-amount")
    assert_operator amounts.size, :>=, 2
    amounts[0].set("10")
    amounts[1].set("2.5")
    find("h1, h2", match: :first).click # leave the field so it reformats

    amounts[0].click(:meta)
    amounts[1].click(:meta)

    assert_selector "#cell-sum", visible: true, text: "12.50"
    refute page.evaluate_script("document.activeElement.classList.contains('posting-amount')"),
           "a ⌘-click must not put the cursor in the amount"

    amounts[0].click
    assert page.evaluate_script("document.activeElement.classList.contains('posting-amount')"),
           "a plain click must still enter the amount"
    assert_no_selector "input.posting-amount[aria-selected]"
    assert_no_selector "#cell-sum", visible: true
  end

  test "the amount being edited becomes the first of the selection when a modifier-click follows" do
    visit app_url("/en/journal_entries/new")
    amounts = all("input.posting-amount")
    amounts[0].set("10")
    amounts[1].set("2.5")

    amounts[0].click                       # editing the first amount
    amounts[1].click(:meta)

    assert_selector "input.posting-amount[aria-selected='true']", count: 2
    assert_selector "#cell-sum", visible: true, text: "12.50"
    refute page.evaluate_script("document.activeElement.classList.contains('posting-amount')"),
           "the edited amount leaves edit mode once it is part of the selection"
    assert_equal "10.00", amounts[0].value # left the field the normal way, so it reformatted
  end

  test "Shift-click extends from the amount being edited" do
    visit app_url("/en/journal_entries/new")
    amounts = all("input.posting-amount")
    amounts[0].set("10")
    amounts[1].set("2.5")

    amounts[0].click
    amounts[1].click(:shift)

    assert_selector "#cell-sum", visible: true, text: "12.50"
  end

  test "an amount no longer being edited does not join the selection" do
    visit app_url("/en/journal_entries/new")
    amounts = all("input.posting-amount")
    amounts[0].set("10")
    amounts[1].set("2.5")

    amounts[0].click
    find("h1, h2", match: :first).click    # left it
    amounts[1].click(:meta)

    assert_selector "input.posting-amount[aria-selected='true']", count: 1
    assert_nil amounts[0]["aria-selected"]
    assert_equal "true", amounts[1]["aria-selected"]
    assert_no_selector "#cell-sum", visible: true
  end

  # Once a posting is split, clicking its amount opens the split modal. Adding
  # that amount to a sum must not.
  test "⌘-clicking a split amount adds it without opening the split modal" do
    visit app_url("/en/journal_entries/new")
    amounts = all("input.posting-amount")
    amounts[0].set("10")
    amounts[1].set("5")
    page.execute_script("document.querySelector('.posting-row .posting-deduction-pair-id').value = 'pair-1'")

    amounts[0].click(:meta)
    amounts[1].click(:meta)
    assert_selector "#cell-sum", visible: true, text: "15.00"
    assert_no_selector "#split-modal[open]"

    amounts[0].click
    assert_selector "#split-modal[open]"
  end
end
