# config/initializers/slack.rb
#
# Slack Ruby client can emit very verbose request/response logs (including headers).
# Keep only compact API call/status lines in app logs.
class SlackCompactLogger
  def initialize(base_logger)
    @base_logger = base_logger
  end

  def info(message = nil, &_block)
    text = message.to_s
    if (m = text.match(/\Arequest: (GET|POST|PUT|PATCH|DELETE) https:\/\/slack\.com\/api\/([A-Za-z0-9._-]+)/))
      @base_logger.info("[SlackAPI] #{m[1]} #{m[2]}")
    elsif (m = text.match(/\Aresponse: Status (\d+)/))
      @base_logger.info("[SlackAPI] status=#{m[1]}")
    end
    true
  end

  def warn(message = nil, &_block)
    @base_logger.warn(message)
  end

  def error(message = nil, &_block)
    @base_logger.error(message)
  end

  def debug(_message = nil, &_block)
    true
  end

  def fatal(message = nil, &_block)
    @base_logger.fatal(message)
  end
end

Slack.configure do |config|
  config.logger = SlackCompactLogger.new(Rails.logger)
  config.token  = nil # we pass tokens at runtime
end
