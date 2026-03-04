# app/services/ai_chat/embedding_service.rb
module AiChat
  class EmbeddingService
    MODEL = ENV.fetch("OPENAI_EMBED_MODEL", "text-embedding-3-small")
    DIMS  = (ENV["OPENAI_EMBED_DIMS"] || "").presence&.to_i

    # Convenience wrapper for a single string.
    def self.embed_one!(text, **opts)
      Array(embed_retrying!([text.to_s], **opts)).first
    end

    def self.embed_retrying!(texts, max_retries: (ENV["OPENAI_EMBED_MAX_RETRIES"] || 8).to_i,
                             base_sleep: (ENV["OPENAI_EMBED_BACKOFF"] || 1.0).to_f,
                             label: "embeddings")
      client  = OpenAI::Client.new
      attempt = 0

      begin
        params = { model: MODEL, input: texts }
        params[:dimensions] = DIMS if DIMS
        puts "[#{label}] request inputs=#{texts.size}" if ENV["VERBOSE"] == "1"
        resp = client.embeddings(parameters: params)
        return resp["data"].map { |d| d["embedding"] }

      rescue => e
        attempt += 1
        status  = (e.respond_to?(:response) && e.response.is_a?(Hash)) ? e.response[:status].to_i : nil
        headers = (e.respond_to?(:response) && e.response.is_a?(Hash)) ? (e.response[:headers] || {}) : {}
        ra      = headers["retry-after"].to_s
        ra_f    = ra =~ /\A\d+(\.\d+)?\z/ ? ra.to_f : 0.0

        # ---- Explicit 429 handling regardless of Faraday/OpenAI error class shape ----
        if status == 429 || e.is_a?(Faraday::TooManyRequestsError)
          raise if attempt > max_retries
          sleep_seconds = ra_f.positive? ? ra_f : (base_sleep * (2 ** (attempt - 1)) + rand * 0.5)
          puts "[#{label}] 429 #{e.class} retry_after=#{ra.presence || 'n/a'} sleeping=#{sleep_seconds.round(2)}s attempt=#{attempt}/#{max_retries}" if ENV["VERBOSE"] == "1"
          sleep(sleep_seconds)
          retry
        end

        # Transients (timeouts/conn)
        if e.is_a?(Faraday::TimeoutError) || e.is_a?(Faraday::ConnectionFailed) || (defined?(OpenAI::Error) && e.is_a?(OpenAI::Error))
          raise if attempt > max_retries
          sleep_seconds = base_sleep * (2 ** (attempt - 1)) + rand * 0.5
          puts "[#{label}] #{e.class} sleeping=#{sleep_seconds.round(2)}s attempt=#{attempt}/#{max_retries}" if ENV["VERBOSE"] == "1"
          sleep(sleep_seconds)
          retry
        end

        # Non-retryable
        puts "[#{label}] non-retryable #{e.class}: #{e.message}" if ENV["VERBOSE"] == "1"
        raise
      end
    end
  end
end
