module Insights
  module QueryHelpers
    POSTED_AT_SQL = "COALESCE(messages.posted_at, messages.created_at)".freeze
  end
end
