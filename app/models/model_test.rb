class ModelTest < ApplicationRecord
  belongs_to :integration
  belongs_to :model
  belongs_to :signal_category

  has_many :model_test_detections, dependent: :destroy

  scope :active, -> { where(active: true) }

  before_save :deactivate_other_actives_if_needed, if: :activating?

  validates :test_type, presence: true

  # NOTE: model_tests table does not have workspace_id. Workspace is derived from the integration.
  def workspace = integration&.workspace
  def workspace_id = integration&.workspace_id

  def self.active_for_inference
    active.includes(:model).order(updated_at: :desc).first
  end

  def self.deactivate_other_actives!(except_id: nil)
    scope = where(active: true)
    scope = scope.where.not(id: except_id) if except_id.present?
    scope.lock.update_all(active: false, updated_at: Time.current)
  end

  # after_create :run_test_async

  def generate_context_for_message(message)
    previous_messages = message.previous_messages(prev_message_count)

    # indicators = SignalIndicator
    #                .joins(signal_subcategory: :signal_category)
    #                .where(signal_categories: { id: signal_category_id })
    #                .pluck(
    #                  'signal_indicators.text',
    #                  'signal_indicators.indicator_type',
    #                  'signal_categories.name',
    #                  'signal_subcategories.name'
    #                )

    # indicator_hashes = indicators.map do |text, type, category, subcategory|
    #   {
    #     signal_category: category,
    #     signal_subcategory: subcategory,
    #     type: type,
    #     indicator_text: text
    #   }
    # end

    previous_messages_hashes = previous_messages.map do |msg|
      {
        sent_at: msg.posted_at.strftime("%Y-%m-%d %H:%M:%S"),
        sender:  msg.workspace_user.display_name,
        role:    "context",
        text:    replace_slack_ids_with_names(msg.text)
      }
    end

    current_message_hash = {
      id:     message.id,
      sender: message.workspace_user.display_name,
      sent_at: message.posted_at.strftime("%Y-%m-%d %H:%M:%S"),
      role:   "evidence",
      text:   replace_slack_ids_with_names(message.text)
    }

    context_json = {
      task: context.presence || "Analyze the message for signal detection",
      instructions: "
        #{self.scoring_instructions}

        #{self.output_instructions}
      ",
      indicators: indicator_hashes,
      previous_messages: previous_messages_hashes,
      current_message: current_message_hash

    }

    {
      inputs: JSON.generate(context_json),
      parameters: {
        return_full_text: false
      }
    }.to_json
  end



  def generate_context_for_review(message, detection: nil)
    # --- readable instruction blocks (no flush-left inside the hash) ---
#     instructions_text = <<~INSTR
#   Judge whether the detection found in the current message with the previous context uses the correct category/submetric, whether its score (-5–5), based on the test instructions text,
#   fits the evidence, and whether the rationale is solid.
#   Respond as JSON with key "ai_quality_score" (0-10) where 0 means it should not have been detected in the current message,
#   a 1-3 would be if the detection is reasonably found, but the score is wrong according to the detected indicator type,
#   a 4-6 would mean the detection is reasonable, but the score or reasoning is extreme (+5 or -5) when it should be more nuanced,
#   a 7-9 would mean the detection is reasonable, the reasoning is accurate, but the score could be adjusted slightly,
#   a 10 means the detection, reasoning, and score are reasonably accurate.
# INSTR

#     instructions_text = <<~INSTR
#   Judge whether the detection found from the current message with the previous context uses the correct category/submetric, whether its score (generated from the following guidelines:
#     Assign a bipolar score from -5 to +5.
#     Positive indicators: use higher values when the message strongly aligns (+5 = very strong evidence).
#     Negative indicators: use lower/negative values when the message strongly aligns (−5 = very strong evidence).
#     Use values near 0 when evidence is weak, ambiguous, or mixed.
#   ) fits the evidence, and whether the rationale is solid.
#   Respond as JSON with key "ai_quality_score" (0-10) where 0 means it should not have been detected in the current message,
#   a 1-3 would be if the detection is reasonably found, but the score is wrong according to the detected indicator type,
#   a 4-6 would mean the detection is reasonable, but the score or reasoning is extreme (+5 or -5) when it should be more nuanced,
#   a 7-9 would mean the detection is reasonable, the reasoning is accurate, but the score could be adjusted slightly,
#   a 10 means the detection, reasoning, and score are reasonably accurate,
#   otherwise make your best assessment, but always provide a score.

#   Your output MUST strictly follow this JSON structure:
#   {
#     "ai_quality_score": integer (score 0 to 10)
#   }

#   Include only the quality score assessed for the detection and return the JSON object with the score.
#   Do not include any additional text, headers, notes, questions, commentary, or explanation.
# INSTR


    instructions_text = <<~INSTR
  Based on the provided context of the current message, a signal for the category was automatically detected by the descriptions of the indicators and given a bipolar score (-5 to 5) based on the strength of alignment and relevancy of the detection in the current message where the negative indicator description should infer a score below zero, and positive should be above zero.
  Judge the detected signal from the current message and its provided context and assess a quality score on scale of 0 through 10 where a 0 would mean the signal should not have been detected at all and a 10 would mean the subcategory and score are reasonable, with slightly off scores or slightly vague categories or subcategories found in the message should be graded on the scale accordingly.
  Respond as JSON with key "ai_quality_score" (0-10)

  Make your best assessment, and always provide a score.

  Your output MUST strictly follow this JSON structure:
  {
    "ai_quality_score": integer (score 0 to 10)
  }

  Include only the quality score assessed for the detection and return the JSON object with the score.
  Do not include any additional text, headers, notes, questions, commentary, or explanation.
INSTR

    test_instructions_text = self.scoring_instructions

    # --- previous messages (safe formatting) ---
    prev_msgs = Array(message.previous_messages(self.prev_message_count))
    previous_messages_hashes = prev_msgs.map do |msg|
      {
        sent_at: msg.posted_at&.strftime("%Y-%m-%d %H:%M:%S"),
        sender:  msg.workspace_user&.display_name.to_s,
        text:    replace_slack_ids_with_names(msg.text.to_s)
      }
    end

    # --- current message ---
    current_message_hash = {
      id:     message.id,
      sender: message.workspace_user&.display_name.to_s,
      sent_at: message.posted_at&.strftime("%Y-%m-%d %H:%M:%S"),
      text:   replace_slack_ids_with_names(message.text.to_s)
    }

    # --- detection under review (prefer provided, else last for this message/test) ---
    det = detection || ModelTestDetection.where(model_test_id: id, message_id: message.id)
                                        .order(created_at: :desc).first

    category  = det&.signal_category
    subcat    = det&.signal_subcategory
    submetric = category&.submetric
    metric    = submetric&.metric
    subcategory_positive = det&.signal_subcategory&.signal_indicators.where(:indicator_type => 'positive').first
    subcategory_negative = det&.signal_subcategory&.signal_indicators.where(:indicator_type => 'negative').first


    # Pull indicator info if you store it; otherwise fall back to detection description
    # indicator = if det&.respond_to?(:signal_indicator) && det.signal_indicator
    #               det.signal_indicator
    #             elsif det&.respond_to?(:signal_indicator_id) && det.signal_indicator_id.present?
    #               SignalIndicator.includes(signal_subcategory: :signal_category).find_by(id: det.signal_indicator_id)
    #             end

    # indicator_info = {
    #   id:          indicator&.id,
    #   text:        indicator&.text || det&.description,
    #   type:        indicator&.indicator_type, # "positive"/"negative" if present
    #   category:    category&.name,
    #   subcategory: subcat&.name
    # }

    # --- a few recent *other* detections for context (derive submetric via association) ---
    # other_detections = ModelTestDetection
    #   .includes(signal_category: :submetric)
    #   .where(model_test_id: id)
    #   .where.not(id: det&.id)
    #   .order(created_at: :desc)
    #   .limit(previous_det_count)
    #   .map { |d|
    #     {
    #       id:           d.id,
    #       submetric_id: d.signal_category&.submetric_id,
    #       description:  d.description,
    #       score:        d.score
    #     }
    #   }

    context_json = {
      task:                 "assess_detection_quality",
      test_context:         self.context,
      current_message:      current_message_hash,
      previous_messages:    previous_messages_hashes,
      # previous_detections:  other_detections,
      detection_under_review: det.present? ? {
        id:                    det.id,
        signal_category_id:    det.signal_category_id,
        signal_subcategory_id: det.signal_subcategory_id,
        submetric_id:          category&.submetric_id,
        metric:                metric&.name,
        submetric:             submetric&.name,
        category:              category&.name,
        subcategory:           subcat&.name,
        subcategory_positive_indicator_description: subcategory_positive,
        subcategory_negative_indicator_description: subcategory_negative,
        description:           det.description,
        score:                 det.score,
        detected_indicator:             indicator_info
      } : nil,
      instructions:        instructions_text,
      # test_instructions:   test_instructions_text
    }

    {
      inputs: JSON.generate(context_json),
      parameters: {
        return_full_text: false
      }
    }.to_json
  end


  def generate_context_for_human_review(message)
    previous_messages = message.previous_messages(prev_message_count)

    # indicators = SignalIndicator
    #                .joins(signal_subcategory: :signal_category)
    #                .where(signal_categories: { id: [1, 2, 3] })
    #                .pluck(
    #                  'signal_indicators.text',
    #                  'signal_indicators.indicator_type',
    #                  'signal_categories.name',
    #                  'signal_subcategories.name'
    #                )

    # indicator_hashes = indicators.map do |text, type, category, subcategory|
    #   { category: category, subcategory: subcategory, type: type, text: text }
    # end

    previous_messages_hashes = previous_messages.map do |msg|
      {
        sent_at: msg.posted_at.strftime("%Y-%m-%d %H:%M:%S"),
        sender:  msg.workspace_user.display_name,
        text:    replace_slack_ids_with_names(msg.text)
      }
    end

    current_message_hash = {
      id:     message.id,
      sender: message.workspace_user.display_name,
      sent_at: msg.posted_at.strftime("%Y-%m-%d %H:%M:%S"),
      text:   replace_slack_ids_with_names(message.text)
    }

    context_json = {
      task: context.presence || "Analyze the message for signal detection",
      # indicators: indicator_hashes,
      current_message: current_message_hash,
      previous_messages: previous_messages_hashes,
      instructions: "
        #{self.scoring_instructions}

        #{self.output_instructions}
      "
    }

    {
      inputs: JSON.generate(context_json),
      parameters: {
        return_full_text: false
      }
    }.to_json
  end



# --- FILTER 1: METRIC --- #
  def generate_context_for_metric_filter(message)
    current_message_hash = {
      id:     message.id,
      text:   replace_slack_ids_with_names(message.text)
    }

    metrics = Metric.all.pluck(:name, :description).map do |name, description|
      {
        name: name,
        description: description
      }
    end

    context_json = {
      task: "Classify message into metrics",
      instructions: "
        #{self.scoring_instructions}

        #{self.output_instructions}
      ",
      current_message: current_message_hash,
      metrics: metrics
    }

    {
      inputs: JSON.generate(context_json),
      parameters: {
        return_full_text: false
      }
    }.to_json
  end


  # --- FILTER 2: SUBMETRIC --- #
  def generate_context_for_submetric_filter(message_metric)
    current_message_hash = {
      id:   message_metric.message.id,
      text: replace_slack_ids_with_names(message_metric.message.text)
    }

    # Get all submetrics for the parent metric
    submetrics = message_metric.metric.submetrics.map do |submetric|
      {
        name: submetric.name,
        description: submetric.description.presence || "No description available"
      }
    end

    context_json = {
      task: "Classify message into submetrics of #{message_metric.metric.name}",
      instructions: "
        #{self.scoring_instructions}

        #{self.output_instructions}
      ",
      current_message: current_message_hash,
      submetrics: submetrics
    }

    {
      inputs: JSON.generate(context_json),
      parameters: {
        return_full_text: false
      }
    }.to_json
  end



  # --- FILTER 3: SIGNAL CATEGORY --- #
  def generate_context_for_signal_category_filter(message_submetric)
    current_message_hash = {
      id:   message_submetric.message.id,
      text: replace_slack_ids_with_names(message_submetric.message.text)
    }

    categories = message_submetric.submetric.signal_categories.map do |cat|
        {
          parent_metric: {
            name: cat.submetric.metric.name
          },
          parent_submetric: {
            name: cat.submetric.name
          },
          category_name: cat.name,
          description: cat.description
        }
      end

    context_json = {
      task: "Classify a message into signal categories of #{message_submetric.submetric.name}",
      instructions: "
        #{self.scoring_instructions}

        #{self.output_instructions}
      ",
      current_message: current_message_hash,
      signal_categories: categories
    }

    {
      inputs: JSON.generate(context_json),
      parameters: {
        return_full_text: false
      }
    }.to_json
  end







  def replace_slack_ids_with_names(text)
    cleaned_text = text.gsub(/<@(\w+)>/) do |match|
      user = WorkspaceUser.find_by(slack_user_id: Regexp.last_match(1))
      user ? "@#{user.display_name}" : match
    end

    # Replace smart quotes with straight quotes and decode unicode sequences
    cleaned_text
      .tr('“”‘’', %q(""''))
      .gsub(/\\u003c/, '<')
      .gsub(/\\u003e/, '>')
  end



  def run_test_async
    RunModelTestJob.perform_later(self.id)
  end

  def provider
    model.openai_deploy? ? "openai" : "sagemaker"
  end

  private

  def activating?
    active? && (new_record? || will_save_change_to_active?)
  end

  def deactivate_other_actives_if_needed
    self.class.deactivate_other_actives!(except_id: id)
  end
end
