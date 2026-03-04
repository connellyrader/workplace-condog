class PartnerProvisioningEvent < ApplicationRecord
  belongs_to :user, optional: true

  validates :contact_id, presence: true, uniqueness: true

  enum status: {
    received:  "received",
    processed: "processed",
    skipped:   "skipped",
    failed:    "failed"
  }
end
