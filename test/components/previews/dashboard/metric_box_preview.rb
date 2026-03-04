# frozen_string_literal: true

class Dashboard::MetricBoxPreview < Lookbook::Preview
  # @label Default (with data)
  def default
    @range_start = 90.days.ago.to_date
    @range_end = Date.current
    @current_group_id = nil
    @group_scope = nil

    metric = Struct.new(:id, :name, :short_description, :reverse?, keyword_init: true).new(
      id: 1,
      name: "Engagement",
      short_description: "Overall team engagement level",
      reverse?: false
    )

    @metric_card_data = {
      1 => {
        points: [60, 65, 68, 70, 72, 74],
        score_available: true,
        score_int: 74,
        metric_delta_abs: 6,
        arrow_dir: "up",
        color_dir: "up",
        show_trend: true,
        enough_data: true,
        has_any_data: true
      }
    }

    render "dashboard/components/metric_box", metric: metric
  end

  # @label No data
  def no_data
    @range_start = 90.days.ago.to_date
    @range_end = Date.current
    @current_group_id = nil
    @group_scope = nil

    metric = Struct.new(:id, :name, :short_description, :reverse?, keyword_init: true).new(
      id: 2,
      name: "Wellbeing",
      short_description: "Employee wellbeing and satisfaction",
      reverse?: false
    )

    @metric_card_data = {
      2 => {
        points: [50, 50],
        score_available: false,
        score_int: nil,
        show_trend: false,
        enough_data: false,
        has_any_data: false
      }
    }

    render "dashboard/components/metric_box", metric: metric
  end
end
