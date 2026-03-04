class Template < ApplicationRecord
  has_many :examples, dependent: :destroy
end
