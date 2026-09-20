# frozen_string_literal: true

class ReportGroupAccount < ApplicationRecord

  belongs_to :report_group, 
             class_name: 'ReportGroup', 
             foreign_key: :report_group_id
  belongs_to :account, 
             class_name: 'Account', 
             foreign_key: :account_id
  validates :account_id, uniqueness: { scope: :report_group_id }
  scope :ordered, -> { order(:position) }

end
