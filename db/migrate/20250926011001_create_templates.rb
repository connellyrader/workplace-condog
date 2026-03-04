class CreateTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :templates do |t|
      t.string :metric, null: false
      t.string :sub_metric, null: false
      t.string :signal_category, null: false
      t.string :signal, null: false
      t.text   :positive_indicator
      t.text   :negative_indicator

      t.timestamps
    end

    create_table :examples do |t|
      t.references :template, null: false, foreign_key: true
      t.string :label, null: false
      t.text   :message, null: false

      t.timestamps
    end
  end
end
