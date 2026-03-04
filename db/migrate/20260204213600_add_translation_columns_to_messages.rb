# frozen_string_literal: true

class AddTranslationColumnsToMessages < ActiveRecord::Migration[7.1]
  def change
    # text_original: stores the original non-English text (null if message was already English)
    # original_language: ISO 639-1 code (e.g., "fr", "es", "de") - null if English
    add_column :messages, :text_original, :text
    add_column :messages, :original_language, :string, limit: 10
  end
end
