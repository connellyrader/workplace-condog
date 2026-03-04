# app/services/messages/purge_service.rb
# Proper text purging that handles encrypted fields correctly

module Messages
  class PurgeService
    def self.purge_message_text(message_id)
      # Use direct SQL to bypass Rails encryption issues
      now = Time.current
      
      sql = <<-SQL
        UPDATE messages 
        SET text = NULL,
            text_original = NULL, 
            text_purged_at = ?,
            updated_at = ?
        WHERE id = ?
      SQL
      
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql([sql, now, now, message_id])
      )
      
      Rails.logger.info "[Messages::PurgeService] Purged message #{message_id}"
    end
    
    def self.purge_messages_batch(message_ids)
      return if message_ids.empty?
      
      now = Time.current
      
      sql = <<-SQL
        UPDATE messages 
        SET text = NULL,
            text_original = NULL,
            text_purged_at = ?,
            updated_at = ?
        WHERE id = ANY(?)
      SQL
      
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql([sql, now, now, "{#{message_ids.join(',')}}"])  
      )
      
      Rails.logger.info "[Messages::PurgeService] Purged #{message_ids.count} messages"
    end
    
    def self.fix_corrupted_purged_messages
      # Emergency fix for existing corrupted data
      corrupted_ids = ActiveRecord::Base.connection.select_values(<<-SQL)
        SELECT id FROM messages 
        WHERE text_purged_at IS NOT NULL 
        AND (text IS NOT NULL OR text_original IS NOT NULL)
      SQL
      
      if corrupted_ids.any?
        Rails.logger.warn "[Messages::PurgeService] Found #{corrupted_ids.count} corrupted purged messages, fixing..."
        
        purge_messages_batch(corrupted_ids)
        
        Rails.logger.info "[Messages::PurgeService] Fixed #{corrupted_ids.count} corrupted purged messages"
      else
        Rails.logger.info "[Messages::PurgeService] No corrupted purged messages found"
      end
    end
  end
end