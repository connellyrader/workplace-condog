module Partners
  class AnalyticsController < BaseController
    def index
      link_ids = current_user.links.select(:id)
      clicks   = LinkClick.where(link_id: link_ids)

      # ---- Referrers (domain) ----
      # If column `referer_domain` exists, use it; otherwise derive from referrer URL.
      referrers = clicks
        .group(Arel.sql(domain_sql_fallback))
        .order(Arel.sql("COUNT(*) DESC"))
        .limit(20)
        .count
      @top_referrers = normalize_referrers(referrers)

      # ---- Countries ----
      # Prefer stored `country`; otherwise everything is "Unknown" until upgrade/backfill.
      if clicks.column_names.include?("country")
        @top_countries = clicks.group(:country).order(Arel.sql("COUNT(*) DESC")).limit(20).count
      else
        @top_countries = { "Unknown" => clicks.count }
      end

      @top_regions = clicks
      .group(:country, :region)
      .order(Arel.sql("COUNT(*) DESC"))
      .limit(5)       # limit in SQL for efficiency
      .count          # => { ["US","California"] => 123, ... }

      # ---- Devices (desktop/mobile/tablet) ----
      # Prefer stored `device_type`. If missing, bucket via UA patterns (fast SQL fallback).
      @top_devices =
        if clicks.column_names.include?("device_type")
          clicks.group(:device_type).order(Arel.sql("COUNT(*) DESC")).count
        else
          clicks.group(Arel.sql(device_bucket_sql)).order(Arel.sql("COUNT(*) DESC")).count
        end

      # ---- Links (by clicks) ----
      raw_link_counts = clicks.group(:link_id).order(Arel.sql("COUNT(*) DESC")).limit(50).count
      links = Link.where(id: raw_link_counts.keys).index_by(&:id)
      @top_links = raw_link_counts.map { |link_id, c|
        link = links[link_id]
        [referral_redirect_url(code: link.code), c]
      }



      # ---- Map points: last 24h clicks -> lat/lng buckets ----
      link_ids = current_user.links.select(:id)
      clicks   = LinkClick.where(link_id: link_ids, created_at: 24.hours.ago..Time.current)
                          .select(:ip) # only need IPs here

      # Resolve lat/lng via local MaxMind (no API calls)
      coords = clicks.map { |lc| geo_latlon(lc.ip) }.compact

      # Bucket to ~0.5° to reduce over-plotting, count per bucket
      buckets = Hash.new(0)
      coords.each do |pt|
        lat = (pt[:lat] * 2).round / 2.0
        lng = (pt[:lng] * 2).round / 2.0
        buckets[[lat, lng]] += 1
      end

      @map_points = buckets.map { |(lat, lng), count| { lat: lat, lng: lng, count: count } }
    end

    private

    # SQL to extract domain from the string referrer, falling back to '(direct)'
    # Uses Postgres: split_part(split_part(...,'//',2), '/', 1) -> host
    def domain_sql_fallback
      if LinkClick.column_names.include?("referer_domain")
        "COALESCE(referer_domain, '(direct)')"
      else
        <<~SQL.squish
          COALESCE(
            NULLIF(
              split_part(split_part(referrer, '://', 2), '/', 1),
              ''
            ),
            '(direct)'
          )
        SQL
      end
    end

    # Very lightweight UA bucketing in SQL (works without gems).
    # You’ll get better accuracy once you persist device_type.
    def device_bucket_sql
      <<~SQL.squish
        CASE
          WHEN user_agent ILIKE '%tablet%' THEN 'tablet'
          WHEN user_agent ILIKE '%ipad%'   THEN 'tablet'
          WHEN user_agent ILIKE '%mobile%' THEN 'mobile'
          WHEN user_agent ILIKE '%iphone%' THEN 'mobile'
          WHEN user_agent ILIKE '%android%' AND user_agent ILIKE '%mobile%' THEN 'mobile'
          WHEN user_agent ILIKE '%android%' AND user_agent NOT ILIKE '%mobile%' THEN 'tablet'
          ELSE 'desktop'
        END
      SQL
    end

    def normalize_referrers(hash)
      # make '(direct)' appear as Direct
      hash.transform_keys { |k| k == "(direct)" ? "Direct" : k }
    end

    # Very small helper using your local mmdb (GeoLite2-City.mmdb)
    def geo_latlon(ip)
      require "ipaddr"
      addr = IPAddr.new(ip) rescue nil
      return nil if addr.nil? || addr.private? || addr.loopback? || addr.link_local?

      return nil unless defined?(MaxMindDB)
      path = Rails.root.join("config/geoip/GeoLite2-City.mmdb")
      return nil unless File.exist?(path)

      @mmdb ||= MaxMindDB.new(path.to_s)
      rec = @mmdb.lookup(ip)
      loc = rec&.location
      return nil unless rec&.found? && loc && loc.latitude && loc.longitude

      { lat: loc.latitude.to_f, lng: loc.longitude.to_f }
    rescue
      nil
    end

  end
end
