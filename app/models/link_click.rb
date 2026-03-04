class LinkClick < ApplicationRecord
  belongs_to :link
  belongs_to :created_user, class_name: "User", optional: true

  # Some columns (is_bot/device_type) are optional in older schemas; keep scope safe.
  scope :human, lambda {
    s = all
    cols = column_names

    s = s.where(is_bot: [false, nil]) if cols.include?("is_bot")
    s = s.where.not(device_type: "bot") if cols.include?("device_type")

    s
  }
end
