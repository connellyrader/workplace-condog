# lib/tasks/fake_messages.rake
require "csv"
require "securerandom"

namespace :dev do
  desc "Import fake messages from CSV into messages (encrypted), marked unprocessed for inference"
  task import_fake_messages: :environment do
    path = ENV["FILE"].presence || ENV["CSV"].presence
    abort "Usage: rake dev:import_fake_messages FILE=path/to/messages.csv" if path.blank?
    abort "File not found: #{path}" unless File.exist?(path)

    integration_id       = (ENV["INTEGRATION_ID"].presence || 42).to_i
    channel_id           = (ENV["CHANNEL_ID"].presence || 2850).to_i
    integration_user_id  = (ENV["INTEGRATION_USER_ID"].presence || 1366).to_i
    limit                = (ENV["LIMIT"].presence || 0).to_i
    dry_run              = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])

    now = Time.current

    puts "[dev:import_fake_messages] file=#{path}"
    puts "[dev:import_fake_messages] integration_id=#{integration_id} channel_id=#{channel_id} integration_user_id=#{integration_user_id}"
    puts "[dev:import_fake_messages] posted_at=#{now.iso8601} dry_run=#{dry_run} limit=#{limit if limit > 0}"

    inserted = 0
    skipped  = 0
    errors   = 0

    preferred_cols = %w[text message body content]

    # Used to generate unique slack_ts values
    base_epoch = now.to_f
    seq = 0

    CSV.foreach(path, headers: true) do |row|
      break if limit > 0 && inserted >= limit

      text =
        preferred_cols.map { |c| row[c] }.find(&:present?) ||
        row.fields.compact.first

      if text.blank?
        skipped += 1
        next
      end

      seq += 1

      # Slack-style ts string "seconds.microseconds"
      # Ensure uniqueness by incrementing micros with seq
      ts_f  = base_epoch + (seq.to_f / 1_000_000.0)
      ts_s  = format("%.6f", ts_f) # e.g. "1700000000.123456"

      msg = Message.new(
        integration_id:       integration_id,
        channel_id:           channel_id,
        integration_user_id:  integration_user_id,
        posted_at:            now,
        text:                 text.to_s,
        subtype:                 text.to_s
      )

      # Required NOT NULL in your schema
      msg.slack_ts = ts_s if msg.respond_to?(:slack_ts=)

      # Keep eligible for inference
      msg.processed_at = nil if msg.respond_to?(:processed_at=)
      msg.processed    = false if msg.respond_to?(:processed=)

      # Optional: if you have other required IDs, set them
      if msg.respond_to?(:provider_message_id=) && msg.provider_message_id.to_s.strip.blank?
        msg.provider_message_id = "fakecsv-#{SecureRandom.uuid}"
      end

      begin
        unless dry_run
          # Save without validations, but still through AR (so encryption/callbacks happen)
          msg.save!(validate: false)
        end

        inserted += 1
        puts "  inserted=#{inserted}" if (inserted % 100).zero?
      rescue => e
        errors += 1
        puts "  ERROR row=#{inserted + skipped + errors}: #{e.class}: #{e.message}"
        next
      end
    end

    puts "[dev:import_fake_messages] DONE inserted=#{inserted} skipped=#{skipped} errors=#{errors} dry_run=#{dry_run}"
  end
end
