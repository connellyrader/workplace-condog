class InsightDriverItem < ApplicationRecord
  belongs_to :insight

  validates :insight, :driver_type, :driver_id, presence: true

  def driver
    driver_type.safe_constantize&.find_by(id: driver_id)
  end
end
