# app/services/ai_chat/context_builder.rb
# frozen_string_literal: true
module AiChat
  class ContextBuilder
    # Keep it minimal and anonymized; the model will pull details via tools.
    def self.build(options:)
      <<~CTX
        === Culture Signal Summary (anonymized) ===
        Use tools to fetch numeric aggregates and trends.
        If needed, fetch definitions for metrics, submetrics, categories, and subcategories via guidance.
      CTX
    end
  end
end
