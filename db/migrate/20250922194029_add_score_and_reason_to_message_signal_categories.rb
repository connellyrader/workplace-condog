class AddScoreAndReasonToMessageSignalCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :message_signal_categories, :score, :integer, null: true
    add_column :message_signal_categories, :reason, :text, null: true
    change_column :message_signal_categories, :full_output, :jsonb, using: 'full_output::jsonb'
  end
end
