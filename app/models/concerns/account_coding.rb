# frozen_string_literal: true

module AccountCoding
  extend ActiveSupport::Concern

  # 6-digit account coding system:
  # Digit 1: Type (1=Assets, 2=Liabilities, 3=Equity, 4=Income, 5=Expenses,
  # 6=Private)
  # Digit 2&3: Entity/User
  # Digit 4: Detail level
  # Digit 5&6: Fine detail

  ACCOUNT_TYPES = {
    1 => :asset,
    2 => :liability,
    3 => :equity,
    4 => :income,
    5 => :expense,
    6 => :personal
  }.freeze

  def type_digit
    code&.first&.to_i
  end

  def entity_code
    code&.[](1, 2)
  end

  def derived_account_type
    ACCOUNT_TYPES[type_digit]
  end

end
