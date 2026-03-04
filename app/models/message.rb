class Message < ApplicationRecord
  # The integration-level user who posted it (Slack/Teams identity)
  belongs_to :integration_user

  # The integration (Slack workspace / Teams tenant, etc.)
  belongs_to :integration

  # Which channel it appeared in
  belongs_to :channel

  # Slack’s per-channel unique timestamp
  validates :slack_ts,
            presence: true,
            uniqueness: { scope: :channel_id }

  has_many :async_inference_results, dependent: :nullify


  # Always store the text unless purged
  validates :text, presence: true, unless: :text_purged?

  # When Slack says it was posted
  validates :posted_at, presence: true

  # Handy scope
  scope :recent, -> { order(posted_at: :desc, slack_ts: :desc) }

  encrypts :text
  encrypts :text_original

  scope :unprocessed_for_references, -> { where(references_processed: false) }

  def previous_messages(count)
    channel.messages
           .where("posted_at < ? AND posted_at >= ?", posted_at, posted_at - 48.hours)
           .order(posted_at: :desc)
           .limit(count)
  end

  def text_purged?
    text_purged_at.present?
  end
end
