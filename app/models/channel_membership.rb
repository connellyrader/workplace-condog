class ChannelMembership < ApplicationRecord
  belongs_to :integration
  belongs_to :channel
  belongs_to :integration_user
end
