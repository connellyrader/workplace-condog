class Group < ApplicationRecord
  belongs_to :workspace

  has_many :group_members, dependent: :destroy
  has_many :integration_users, through: :group_members
  has_many :insights, as: :subject, dependent: :destroy
end
