namespace :slack do
  desc "Fetch Slack events from S3 (written by Lambda) and persist messages. ENV: LIMIT, AWS_REGION, SLACK_EVENTS_BUCKET, SLACK_EVENTS_PREFIX"
  task fetch_events: :environment do
    limit   = (ENV["LIMIT"] || Slack::EventFetcher::DEFAULT_LIMIT).to_i
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    puts "SlackEventFetcher: scanning up to #{limit} files…"
    processed = Slack::EventFetcher.call(limit: limit)
    elapsed   = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)

    puts "SlackEventFetcher: processed #{processed} files in #{elapsed}s"
  rescue => e
    puts "SlackEventFetcher: error #{e.class} #{e.message}"
    raise
  end
end
