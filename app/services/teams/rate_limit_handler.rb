# app/services/teams/rate_limit_handler.rb
# Enhanced rate limiting with exponential backoff and message queuing

module Teams
  class RateLimitHandler
    MAX_RETRIES = 5
    INITIAL_BACKOFF = 60 # seconds
    MAX_BACKOFF = 3600 # 1 hour max
    
    def self.with_retry(integration:, operation:, &block)
      new(integration).with_retry(operation, &block)
    end
    
    def initialize(integration)
      @integration = integration
    end
    
    def with_retry(operation_name)
      retries = 0
      
      loop do
        begin
          # Check if we're currently rate limited
          if currently_rate_limited?
            wait_time = time_until_rate_limit_clears
            if wait_time > 0
              Rails.logger.info "[Teams::RateLimitHandler] Integration #{@integration.id} waiting #{wait_time}s for rate limit to clear"
              sleep(wait_time)
            end
          end
          
          # Try the operation
          return yield
          
        rescue => e
          if rate_limit_error?(e) && retries < MAX_RETRIES
            retry_after = extract_retry_after(e)
            retries += 1
            
            # Exponential backoff with jitter
            backoff_time = calculate_backoff(retries, retry_after)
            
            Rails.logger.warn "[Teams::RateLimitHandler] #{operation_name} rate limited (attempt #{retries}/#{MAX_RETRIES}), waiting #{backoff_time}s"
            
            # Mark integration users as rate limited
            mark_integration_rate_limited(backoff_time)
            
            # Wait before retry
            sleep(backoff_time)
            
          else
            # Non-rate-limit error or max retries exceeded
            if retries >= MAX_RETRIES
              Rails.logger.error "[Teams::RateLimitHandler] #{operation_name} failed after #{MAX_RETRIES} retries due to rate limiting"
            end
            raise e
          end
        end
      end
    end
    
    private
    
    def currently_rate_limited?
      @integration.integration_users
                  .where("rate_limited_until > ?", Time.current)
                  .exists?
    end
    
    def time_until_rate_limit_clears
      max_rate_limit = @integration.integration_users
                                  .where("rate_limited_until > ?", Time.current)
                                  .maximum(:rate_limited_until)
      
      return 0 unless max_rate_limit
      
      (max_rate_limit - Time.current).to_i
    end
    
    def rate_limit_error?(error)
      error.message.include?("429") || 
      error.message.include?("TooManyRequests") ||
      error.message.include?("rate limit")
    end
    
    def extract_retry_after(error)
      # Try to extract retry-after from error message
      if error.message =~ /retry[-_\s]*after[:\s]*(\d+)/i
        $1.to_i
      elsif error.respond_to?(:response) && error.response&.headers
        error.response.headers["retry-after"]&.to_i
      else
        nil
      end
    end
    
    def calculate_backoff(retry_count, suggested_retry_after)
      # Use Microsoft's suggested retry-after if available
      if suggested_retry_after && suggested_retry_after > 0
        base_time = suggested_retry_after
      else
        base_time = INITIAL_BACKOFF
      end
      
      # Exponential backoff: 60s, 120s, 240s, 480s, 960s, max 3600s
      exponential_time = base_time * (2 ** (retry_count - 1))
      
      # Cap at maximum and add jitter to avoid thundering herd
      capped_time = [exponential_time, MAX_BACKOFF].min
      jitter = rand(0.1..0.3) * capped_time
      
      (capped_time + jitter).to_i
    end
    
    def mark_integration_rate_limited(backoff_time)
      until_time = Time.current + backoff_time.seconds
      
      @integration.integration_users.update_all(
        rate_limited_until: until_time,
        rate_limit_last_retry_after_seconds: backoff_time
      )
      
      Rails.logger.info "[Teams::RateLimitHandler] Marked integration #{@integration.id} as rate limited until #{until_time}"
    end
    
    # Message queuing for failed operations (optional enhancement)
    def queue_for_retry(operation_data)
      # Store failed operation in Redis or database for later retry
      retry_key = "teams:retry:#{@integration.id}:#{SecureRandom.hex(8)}"
      
      Redis.current.setex(
        retry_key,
        24.hours.to_i, # Expire after 24 hours
        {
          integration_id: @integration.id,
          operation: operation_data,
          queued_at: Time.current.iso8601,
          retry_count: 0
        }.to_json
      )
      
      Rails.logger.info "[Teams::RateLimitHandler] Queued operation #{retry_key} for later retry"
    end
    
    def self.process_retry_queue
      # Process queued operations (could be run by separate cron job)
      retry_keys = Redis.current.keys("teams:retry:*")
      
      retry_keys.each do |key|
        begin
          operation_data = JSON.parse(Redis.current.get(key))
          
          integration = Integration.find(operation_data["integration_id"])
          
          # Only retry if rate limit has cleared
          unless integration.integration_users.where("rate_limited_until > ?", Time.current).exists?
            # Retry the operation
            # (implementation depends on operation type)
            Rails.logger.info "[Teams::RateLimitHandler] Retrying queued operation #{key}"
            Redis.current.del(key)
          end
          
        rescue => e
          Rails.logger.error "[Teams::RateLimitHandler] Failed to process retry #{key}: #{e.message}"
        end
      end
    end
    
    private
    
    def parse_time(str)
      return nil if str.blank?
      Time.parse(str) rescue nil
    end
  end
end