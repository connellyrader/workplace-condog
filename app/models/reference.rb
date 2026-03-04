class Reference < ApplicationRecord
  self.table_name = "references"

  has_many :reference_mentions, dependent: :destroy
  has_many :messages, through: :reference_mentions

  KINDS = %w[project event doc deal code_link meeting_link generic_link id_token topic].freeze
  validates :kind,  presence: true, inclusion: { in: KINDS }
  validates :value, presence: true
end
