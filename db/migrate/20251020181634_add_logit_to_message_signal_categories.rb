class AddLogitToMessageSignalCategories < ActiveRecord::Migration[7.1]
  def change
    add_column :message_signal_categories, :logit_score, :float 
    add_column :message_signal_categories, :logit_ratio, :float 
    add_column :signal_categories, :positive_threshold, :float 
    add_column :signal_categories, :negative_threshold, :float 

    remove_column :message_signal_categories, :reason
    drop_table :detected_signals 
    drop_table :signal_indicators
    drop_table :signal_definition_framework_subcategories 
    drop_table :signal_definition_subcategories 
    drop_table :signal_definitions
    drop_table :subcategories
    drop_table :categories 
    drop_table :framework_subcategories 
    drop_table :frameworks 
    drop_table :message_submetrics 
    drop_table :message_metrics 
    
    
    rename_table :message_signal_categories, :detections 
    

  end
end
