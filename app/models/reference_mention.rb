class ReferenceMention < ApplicationRecord
  belongs_to :reference
  belongs_to :message

  validates :message_id, :reference_id, presence: true
end
