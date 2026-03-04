class TeamMembership < ApplicationRecord
  belongs_to :team
  belongs_to :integration_user
end
