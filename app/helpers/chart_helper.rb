# app/helpers/chart_helper.rb
module ChartHelper
  def sparkline_paths(values,
                      width: 320, height: 110,
                      top: 0, bottom: 0,
                      pad_pct: 0.20, # kept for compatibility; not used in fixed-domain mode
                      curve: :linear,
                      curve_pad_px: 8,
                      curve_tension: 0.7)
    raise ArgumentError, "need at least 2 points" if values.size < 2

    # VISUALS ONLY:
    # - treat nil / non-numeric / NaN / Infinity as 50
    # - clamp to 0..100
    cleaned = values.map { |v| normalize_spark_value(v) }

    usable_w = width.to_f
    usable_h = (height - top - bottom).to_f
    base_y   = height - bottom

    # FIXED DOMAIN: always show full 0..100 so 50 is always the midpoint
    # Add a small inset when smoothing to prevent bezier overshoot clipping.
    inset =
      if curve.to_s == "smooth"
        curve_pad_px.to_f
      else
        0.0
      end

    inset = [[inset, 0.0].max, (usable_h / 2.0 - 1.0)].min

    y_min = top + inset
    y_max = top + usable_h - inset

    pts = cleaned.each_with_index.map do |v, i|
      x = (i.to_f / (cleaned.size - 1)) * usable_w

      # map 0..100 into [y_min..y_max]
      frac = 1.0 - (v / 100.0)
      y = y_min + (y_max - y_min) * frac

      [round2(x), round2(y)]
    end

    line_d =
      case curve
      when :smooth
        path_cubic_catmull_rom(
          pts,
          tension: curve_tension,
          y_min: round2(y_min),
          y_max: round2(y_max)
        )
      else
        "M #{pts.first.join(' ')} " + pts.drop(1).map { |x, y| "L #{x} #{y}" }.join(" ")
      end

    area_d = "#{line_d} L #{pts.last.first} #{round2(base_y)} L #{pts.first.first} #{round2(base_y)} Z"

    {
      line:   line_d,
      area:   area_d,
      base_y: round2(base_y),
      points: pts,
      min:    0.0,
      max:    100.0
    }
  end

  private

  def float_or_nil(v)
    return nil if v.nil?
    Float(v)
  rescue
    nil
  end

  def normalize_spark_value(v)
    f = float_or_nil(v)
    f = 50.0 if f.nil? || !f.finite?
    [[f, 0.0].max, 100.0].min
  end

  # Smooth curve: Catmull–Rom -> cubic Beziers with optional Y clamping
  def path_cubic_catmull_rom(points, tension: 0.5, y_min: nil, y_max: nil)
    return "M #{points.first.join(' ')}" if points.length < 2

    t = [[tension.to_f, 0.0].max, 1.0].min

    fetch = ->(idx) do
      i = [[idx, 0].max, points.length - 1].min
      points[i]
    end

    clamp_y = ->(y) do
      yy = y.to_f
      if !y_min.nil? && !y_max.nil?
        [[yy, y_min.to_f].max, y_max.to_f].min
      else
        yy
      end
    end

    d = +"M #{points.first.join(' ')}"

    (0...(points.length - 1)).each do |i|
      p0x, p0y = fetch.call(i - 1)
      p1x, p1y = fetch.call(i)
      p2x, p2y = fetch.call(i + 1)
      p3x, p3y = fetch.call(i + 2)

      c1x = p1x + (p2x - p0x) * (t / 6.0)
      c1y = p1y + (p2y - p0y) * (t / 6.0)
      c2x = p2x - (p3x - p1x) * (t / 6.0)
      c2y = p2y - (p3y - p1y) * (t / 6.0)

      # Prevent overshoot from clipping at top/bottom
      c1y = clamp_y.call(c1y)
      c2y = clamp_y.call(c2y)

      d << " C #{round2(c1x)} #{round2(c1y)} #{round2(c2x)} #{round2(c2y)} #{round2(p2x)} #{round2(p2y)}"
    end

    d
  end

  def round2(n) = (n.to_f * 100).round / 100.0
end
