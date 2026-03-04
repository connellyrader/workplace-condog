class BackfillChannelIdentities < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    now = Time.current

    say_with_time "Backfilling channel identities from existing channels" do
      Channel.includes(:integration)
             .where.not(external_channel_id: [nil, ""])
             .find_in_batches(batch_size: 500) do |batch|
        rows = batch.map do |channel|
          provider = channel.integration&.kind.presence || "slack"

          {
            integration_id:      channel.integration_id,
            channel_id:          channel.id,
            integration_user_id: nil,
            provider:            provider,
            external_channel_id: channel.external_channel_id,
            discovered_at:       now,
            last_seen_at:        now,
            created_at:          now,
            updated_at:          now
          }
        end

        ChannelIdentity.insert_all(rows, unique_by: :idx_channel_identities_on_integration_provider_extid) if rows.any?
      end
    end
  end

  def down
    ChannelIdentity.delete_all
  end
end
