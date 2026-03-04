# Microsoft Teams (parent groups internal to MS, not groups in our system)
class Team < ApplicationRecord
  belongs_to :integration
  has_many   :team_memberships, dependent: :destroy
  has_many   :integration_users, through: :team_memberships
end
