# app/controllers/ai_chat/charts_controller.rb
class AiChat::ChartsController < ApplicationController
  before_action :authenticate_user!

  # GET /ai_chat/sparkline?t=SIGNED
  def sparkline
    pld = AiChat::Sparkline.verify!(params[:t])
    return head :forbidden unless pld
    p = pld.respond_to?(:with_indifferent_access) ? pld.with_indifferent_access : pld

    from_d = parse_dateish(p[:start_date]) || parse_dateish(p[:from])
    to_d   = parse_dateish(p[:end_date])   || parse_dateish(p[:to])
    unless from_d && to_d
      Rails.logger.error("[sparkline] missing/invalid dates: start=#{p[:start_date].inspect} end=#{p[:end_date].inspect}")
      return head :bad_request
    end

    points = AiChat::DataQueries.timeseries(
      user: current_user,
      category: p[:category],
      from: from_d.beginning_of_day,
      to:   to_d.end_of_day,
      metric: (p[:metric] || :pos_rate).to_sym,
      metric_ids:     intval_array(p[:metric_ids]),
      submetric_ids:  intval_array(p[:submetric_ids]),
      subcategory_ids:intval_array(p[:subcategory_ids])
    )

    render inline: svg_for(points, width: (params[:w] || 280).to_i, height: (params[:h] || 40).to_i),
           content_type: "image/svg+xml"
  rescue => e
    Rails.logger.error("[sparkline] #{e.class}: #{e.message}")
    head :bad_request
  end

  private

  def intval_array(v)
    a = Array(v).map { |x| Integer(x) rescue nil }.compact
    a.presence
  end

  def parse_dateish(v)
    return v if v.is_a?(Date)
    return v.to_date if v.respond_to?(:to_date)
    return nil if v.blank?
    Date.parse(v.to_s)
  rescue
    nil
  end

  def svg_for(points, width:, height:)
    vals = points.map { |p| p[:value] }.compact
    return blank_svg(width, height) if vals.empty?
    min, max = vals.min, vals.max
    max = min + 1e-6 if max == min
    step = (width - 6).to_f / [points.size - 1, 1].max
    coords = points.each_with_index.map do |p, i|
      v = p[:value]; next nil if v.nil?
      x = 3 + i * step
      y = (height - 3) - ((v - min) / (max - min)) * (height - 6)
      [x.round(2), y.round(2)]
    end.compact
    path = coords.map.with_index { |(x,y),i| "#{i.zero? ? 'M' : 'L'}#{x},#{y}" }.join(" ")
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">
        <rect width="100%" height="100%" fill="white"/>
        <path d="#{path}" fill="none" stroke="#222" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
    SVG
  end

  def blank_svg(w,h)
    %Q{<svg xmlns="http://www.w3.org/2000/svg" width="#{w}" height="#{h}"><rect width="100%" height="100%" fill="white"/></svg>}
  end
end
