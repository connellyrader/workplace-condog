require "openai"

OpenAI.configure do |config|
  config.access_token = ENV.fetch("OPENAI_API_KEY")
  beta_header = ENV["OPENAI_BETA_HEADER"].presence || "assistants=v2"
  config.extra_headers = { "OpenAI-Beta" => beta_header } if beta_header.present?
end
