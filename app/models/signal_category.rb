class SignalCategory < ApplicationRecord
  belongs_to :submetric
  has_many :signal_subcategories
end
