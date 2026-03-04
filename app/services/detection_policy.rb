# frozen_string_literal: true

# Single source of truth for detection scoring filters used across dashboard/rollups/chat.
#
# Storage can remain broad (e.g., save detections with margin > 0), while serving/scoring
# applies this policy consistently:
# - polarity-specific margin mins
# - polarity-specific per-message top-k
#
module DetectionPolicy
  module_function

  def pos_margin_min
    ENV.fetch("DETECTION_POS_MARGIN_MIN", "1.8").to_f
  end

  def neg_margin_min
    ENV.fetch("DETECTION_NEG_MARGIN_MIN", "3.2").to_f
  end

  def pos_top_k
    ENV.fetch("DETECTION_POS_TOP_K", "10").to_i
  end

  def neg_top_k
    ENV.fetch("DETECTION_NEG_TOP_K", "5").to_i
  end

  # SQL predicate for a rowset that has polarity + margin + (id,message_id).
  # Defaults assume detections table alias.
  def sql_condition(table_alias: "detections", id_col: "id", message_id_col: "message_id", polarity_col: "polarity", margin_col: "logit_margin")
    t = table_alias

    <<~SQL.squish
      (
        (
          #{t}.#{polarity_col} = 'positive'
          AND #{t}.#{margin_col} >= #{pos_margin_min}
          AND (
            SELECT COUNT(*)
            FROM detections d2
            WHERE d2.message_id = #{t}.#{message_id_col}
              AND d2.polarity = 'positive'
              AND (
                d2.logit_margin > #{t}.#{margin_col}
                OR (d2.logit_margin = #{t}.#{margin_col} AND d2.id >= #{t}.#{id_col})
              )
          ) <= #{pos_top_k}
        )
        OR
        (
          #{t}.#{polarity_col} = 'negative'
          AND #{t}.#{margin_col} >= #{neg_margin_min}
          AND (
            SELECT COUNT(*)
            FROM detections d2
            WHERE d2.message_id = #{t}.#{message_id_col}
              AND d2.polarity = 'negative'
              AND (
                d2.logit_margin > #{t}.#{margin_col}
                OR (d2.logit_margin = #{t}.#{margin_col} AND d2.id >= #{t}.#{id_col})
              )
          ) <= #{neg_top_k}
        )
      )
    SQL
  end
end
