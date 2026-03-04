# app/controllers/referrals_controller.rb
class ReferralsController < ApplicationController
  skip_before_action :authenticate_user!

  def track
    code = params[:code].to_s.strip
    link = Link.where("lower(code) = ?", code.downcase).first
    return redirect_to "https://workplace.io", allow_other_host: true unless link

    # Stable browser/session ID for attribution
    cookies.permanent[:click_uuid] ||= SecureRandom.uuid

    ua       = request.user_agent.to_s
    ref      = request.referer.to_s
    ip       = client_ip
    domain   = extract_domain(ref)
    device, ua_extra = bucket_device(ua) # [device_type, { os:, browser:, is_mobile:, is_bot: }]
    geo      = lookup_geo(ip)            # { country:, region:, city: } ({} if none/localhost)

    attrs = {
      link:       link,
      ip:         ip,
      user_agent: ua,
      referrer:   ref,
      click_uuid: cookies[:click_uuid]
    }

    # Optional columns (only set if they exist)
    add_if_column(attrs, :referer_domain, domain)
    add_if_column(attrs, :device_type,    device)
    add_if_column(attrs, :os,             ua_extra[:os])
    add_if_column(attrs, :browser,        ua_extra[:browser])
    add_if_column(attrs, :is_mobile,      ua_extra[:is_mobile])
    add_if_column(attrs, :is_bot,         ua_extra[:is_bot])
    add_if_column(attrs, :country,        geo[:country])
    add_if_column(attrs, :region,         geo[:region])
    add_if_column(attrs, :city,           geo[:city])

    LinkClick.create!(attrs)

    cookies.permanent.signed[:referral_link_id] = link.id
    redirect_to "https://workplace.io", allow_other_host: true
  end

  private

  # Prefer real client IP if behind a proxy/CDN; fall back to remote_ip.
  def client_ip
    # Cloudflare first (harmless if not present)
    return request.headers['CF-Connecting-IP'] if request.headers['CF-Connecting-IP'].present?

    # Standard proxy chain; take the first public IP
    if (xff = request.headers['X-Forwarded-For']).present?
      ip = xff.split(',').map(&:strip).find { |cand| public_ip?(cand) }
      return ip if ip.present?
    end

    request.remote_ip
  end

  def public_ip?(ip)
    addr = IPAddr.new(ip) rescue nil
    return false unless addr
    !(addr.private? || addr.loopback? || addr.link_local?)
  end

  # Add a key/value only if the column exists on link_clicks
  def add_if_column(h, col, val)
    return if val.nil?
    if @__lc_cols.nil?
      @__lc_cols = LinkClick.column_names # cache once per request
    end
    h[col] = val if @__lc_cols.include?(col.to_s)
  end

  # Extract host from URL; downcase, strip "www.", fallback to "(direct)"
  def extract_domain(url)
    return "(direct)" if url.blank?
    host = url.split('://', 2).last.to_s.split('/', 2).first.to_s.downcase
    host.sub!(/\Awww\./, '')
    host.presence || "(direct)"
  end

  # Device bucketing via device_detector gem
  def bucket_device(ua)
    dd = DeviceDetector.new(ua.to_s)
    device =
      if dd.bot? then "bot"
      elsif dd.device_type == "smartphone" then "mobile"
      elsif dd.device_type == "tablet" then "tablet"
      else "desktop"
      end
    info = {
      os:        dd.os_name,
      browser:   dd.name,
      is_mobile: %w[mobile tablet].include?(device),
      is_bot:    dd.bot?
    }
    [device, info]
  end

  # GeoIP from local MaxMind mmdb (config/geoip/GeoLite2-City.mmdb)
  # Returns {} for private/loopback IPs or when file missing/not found.
  def lookup_geo(ip)
    begin
      addr = IPAddr.new(ip)
      return {} if addr.private? || addr.loopback? || addr.link_local?
    rescue
      return {}
    end

    return {} unless defined?(MaxMindDB)
    db_path = Rails.root.join("config/geoip/GeoLite2-City.mmdb")
    return {} unless File.exist?(db_path)

    @mmdb ||= MaxMindDB.new(db_path.to_s)
    rec = @mmdb.lookup(ip)
    return {} unless rec.found?

    {
      country: rec.country&.iso_code,              # "US"
      region:  rec.subdivisions&.first&.name,      # "California"
      city:    rec.city&.name                      # "San Francisco"
    }.compact
  rescue => e
    Rails.logger.debug("GeoIP error: #{e.class} #{e.message}")
    {}
  end
end
