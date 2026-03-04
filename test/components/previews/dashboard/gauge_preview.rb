# frozen_string_literal: true

class Dashboard::GaugePreview < Lookbook::Preview
  # @param score range { min: 0, max: 100, step: 1 }
  # @label Interactive
  def default(score: 72)
    @value = score
    @gauge_value = score
    @notch1 = 25
    @notch2 = 75
    @trend_delta = 5
    @range_phrase = "Last 90 days"
    @is_all_time = false
    @score_available = true
    @active_workspace = Struct.new(:id, :name).new(nil, "Preview")
    @metric = Struct.new(:name, :reverse?).new("Culture Score", false)

    render "dashboard/components/gauge"
  end

  # @label High score
  def high_score
    @value = 88
    @gauge_value = 88
    @notch1 = 25
    @notch2 = 75
    @trend_delta = 12
    @range_phrase = "Last 90 days"
    @is_all_time = false
    @score_available = true
    @active_workspace = Struct.new(:id, :name).new(nil, "Preview")
    @metric = Struct.new(:name, :reverse?).new("Engagement", false)

    render "dashboard/components/gauge"
  end

  # @label Low score
  def low_score
    @value = 18
    @gauge_value = 18
    @notch1 = 25
    @notch2 = 75
    @trend_delta = -3
    @range_phrase = "Last 30 days"
    @is_all_time = false
    @score_available = true
    @active_workspace = Struct.new(:id, :name).new(nil, "Preview")
    @metric = Struct.new(:name, :reverse?).new("Performance", false)

    render "dashboard/components/gauge"
  end

  # @label No data
  def no_data
    @value = nil
    @gauge_value = nil
    @score_available = false
    @active_workspace = Struct.new(:id, :name).new(nil, "Preview")

    render "dashboard/components/gauge"
  end
end
