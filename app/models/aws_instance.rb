# app/models/aws_instance.rb
class AwsInstance < ApplicationRecord
  has_many :models, dependent: :nullify

  validates :instance_type, presence: true, uniqueness: true
  validates :hourly_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  def label
    dollars = hourly_price ? (hourly_price.to_f / 100.0) : nil
    price   = dollars ? format("$%.4f/hr", dollars) : "price N/A"
    "#{instance_type} (#{price})"
  end
end
