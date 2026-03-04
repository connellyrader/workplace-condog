class Subscription < ApplicationRecord
  belongs_to :user
  belongs_to :workspace, optional: true

  has_many :charges, dependent: :destroy

  validates :stripe_subscription_id, presence: true, uniqueness: true

  def monthly?
    interval == "month"
  end

  def yearly?
    interval == "year"
  end
end
