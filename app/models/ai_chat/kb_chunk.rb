# app/models/ai_chat/kb_chunk.rb
class AiChat::KbChunk < ApplicationRecord
  self.table_name = "kb_chunks"
  validates :namespace, :title, :body, presence: true
end
