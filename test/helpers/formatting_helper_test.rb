require "test_helper"

class FormattingHelperTest < ActionView::TestCase
  include FormattingHelper

  test "transaction_type_from_counter_accounts returns Income for income counter" do
    counter_accounts = [[1, 2, "410001", "Sales", "income", 1, 10000, "GBP"]]
    assert_equal "Income", transaction_type_from_counter_accounts(counter_accounts)
  end

  test "transaction_type_from_counter_accounts returns Expense for expense counter" do
    counter_accounts = [[1, 2, "510001", "Expenses", "expense", 0, 10000, "GBP"]]
    assert_equal "Expense", transaction_type_from_counter_accounts(counter_accounts)
  end

  test "transaction_type_from_counter_accounts returns Personal for personal counter" do
    counter_accounts = [[1, 2, "610001", "Drawings", "personal", 0, 10000, "GBP"]]
    assert_equal "Personal", transaction_type_from_counter_accounts(counter_accounts)
  end

  test "transaction_type_from_counter_accounts returns Transfer for balance sheet counter" do
    counter_accounts = [[1, 2, "140001", "Other Bank", "asset", 0, 10000, "GBP"]]
    assert_equal "Transfer", transaction_type_from_counter_accounts(counter_accounts)
  end

  test "transaction_type_from_counter_accounts returns Split for multiple counters" do
    counter_accounts = [
      [1, 2, "410001", "Sales", "income", 1, 5000, "GBP"],
      [1, 3, "510001", "Expenses", "expense", 0, 5000, "GBP"]
    ]
    assert_equal "Split", transaction_type_from_counter_accounts(counter_accounts)
  end

  test "transaction_type_from_counter_accounts returns Unknown for empty" do
    assert_equal "Unknown", transaction_type_from_counter_accounts([])
  end
end