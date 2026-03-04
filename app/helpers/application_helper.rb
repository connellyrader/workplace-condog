module ApplicationHelper
  def delta_pct(cur, prev)
    return "—" if prev.to_i == 0 && cur.to_i == 0
    return "+∞%" if prev.to_i == 0 && cur.to_i > 0
    pct = ((cur.to_f - prev.to_f) / prev.to_f) * 100.0
    format("%+0.1f%%", pct)
  end

  def delta_money(cur_cents, prev_cents)
    cur  = cur_cents.to_i / 100.0
    prev = prev_cents.to_i / 100.0
    return "—" if prev.zero? && cur.zero?
    return "+∞%" if prev.zero? && cur.positive?
    pct = ((cur - prev) / prev) * 100.0
    format("%+0.1f%%", pct)
  end
end
