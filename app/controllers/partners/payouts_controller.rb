# app/controllers/partners/payouts_controller.rb
module Partners
  class PayoutsController < Partners::BaseController
    respond_to :html, :csv, only: [:index, :show]

    def index
      last_month    = Date.today.prev_month
      current_month = Date.today

      @real_payouts = current_user.payouts
                                  .order(Arel.sql("COALESCE(paid_at, created_at) DESC"))

      # Always show the first pseudo payout (even if $0)
      upcoming = build_pseudo_payout_for(
        user: current_user, id: "next", month: last_month, label: "Upcoming Payout"
      )
      @pseudo_payouts = [upcoming]

      # Only show the second one if amount > 0
      future = build_pseudo_payout_for(
        user: current_user, id: "future", month: current_month, label: "Upcoming Payout"
      )
      @pseudo_payouts << future if future.amount.to_i > 0
      @pseudo_payouts.reverse!

      respond_to do |format|
        format.html
        format.csv do
          require "csv"

          headers = %w[id period_start period_end payout_date amount status]
          rows = []

          # Pseudo rows
          @pseudo_payouts.each do |p|
            rows << [
              p.id,
              p.start_date&.strftime("%Y-%m-%d"),
              p.end_date&.strftime("%Y-%m-%d"),
              p.payout_date&.strftime("%Y-%m-%d"),
              format("%.2f", p.amount.to_i / 100.0),
              "pending"
            ]
          end

          # Real rows
          @real_payouts.each do |p|
            status = p.paid_at.present? ? "completed" : "processing"
            rows << [
              p.id,
              p.start_date&.strftime("%Y-%m-%d"),
              p.end_date&.strftime("%Y-%m-%d"),
              (p.paid_at || p.created_at)&.strftime("%Y-%m-%d"),
              format("%.2f", p.amount.to_i / 100.0),
              status
            ]
          end

          csv = CSV.generate do |out|
            out << headers
            rows.each { |r| out << r }
          end

          send_data csv,
            filename: "payouts-#{Time.zone.today}.csv",
            disposition: "attachment",
            type: "text/csv; charset=utf-8"
        end
      end
    end

    def show
      case params[:id]
      when "next"
        month = Date.today.prev_month
        @payout = build_pseudo_payout_for(
          user: current_user, id: "next", month: month, label: "Upcoming Payout"
        )
      when "future"
        month = Date.today
        @payout = build_pseudo_payout_for(
          user: current_user, id: "future", month: month, label: "Upcoming Payout"
        )
      else
        @payout  = current_user.payouts.find(params[:id])
        @charges = @payout.charges.includes(:subscription, :customer)
      end

      respond_to do |format|
        format.html
        format.csv do
          require "csv"

          # Use charges loaded above (for real payouts), or the OpenStruct list (for pseudo)
          charges = @charges || @payout.charges

          header_row = [
            "period_start", @payout.start_date&.strftime("%Y-%m-%d"),
            "period_end",   @payout.end_date&.strftime("%Y-%m-%d"),
            (@payout.respond_to?(:payout_date) ? "expected_payout_date" : "payout_date"),
            (@payout.respond_to?(:payout_date) ? @payout.payout_date : (@payout.paid_at || @payout.created_at))&.strftime("%Y-%m-%d"),
            "amount", format("%.2f", @payout.amount.to_i / 100.0)
          ]

          charge_headers = %w[id date customer_email plan amount commission payout_id]
          charge_rows =
            Array(charges).map do |c|
              [
                c.id,
                c.created_at&.in_time_zone&.strftime("%Y-%m-%d"),
                c.customer&.email,
                c.subscription&.interval&.capitalize,
                format("%.2f", c.amount.to_i / 100.0),
                format("%.2f", c.commission.to_i / 100.0),
                (c.payout_id || "")
              ]
            end

          csv = CSV.generate do |out|
            out << header_row
            out << [] # spacer
            out << charge_headers
            charge_rows.each { |r| out << r }
          end

          id_for_filename =
            if @payout.respond_to?(:id) && @payout.id.present?
              @payout.id
            else
              @payout.respond_to?(:label) ? @payout.label.parameterize : "pseudo"
            end

          send_data csv,
            filename: "payout-#{id_for_filename}-#{Time.zone.today}.csv",
            disposition: "attachment",
            type: "text/csv; charset=utf-8"
        end
      end
    end

    def banking
      @trolley_widget_url = build_trolley_widget_url!(current_user, products: "pay,tax")
    rescue => e
      Rails.logger.warn("[Trolley] Widget URL error: #{e.class} - #{e.message}")
      flash.now[:alert] = "We couldn't load the banking widget. Please try again in a moment."
      @trolley_widget_url = nil
    end

    private

    def build_trolley_widget_url!(user, products:)
      access_key = ENV["TROLLEY_ACCESS_KEY"]
      secret_key = ENV["TROLLEY_SECRET_KEY"]
      raise "Missing TROLLEY_ACCESS_KEY/TROLLEY_SECRET_KEY" if access_key.blank? || secret_key.blank?

      refid  = user.try(:trolley_refid).presence || "user-#{user.id}"
      email  = user.email

      params = {
        ts: Time.now.to_i,     # short-lived signature window
        key: access_key,
        email: email,
        refid: refid,
        hideEmail: "false",
        roEmail: "true",
        locale: "en",
        products: products     # e.g. "pay,tax" or "pay,tax,trust"
        # Optional:
        # "addr.country": "US",
        # "colors.primary":  "#111827"
      }

      # Canonical querystring (spaces must be %20, not '+')
      qs = URI.encode_www_form(params).gsub("+", "%20")

      sign = OpenSSL::HMAC.hexdigest("SHA256", secret_key, qs)

      "https://widget.trolley.com?#{qs}&sign=#{sign}"
    end
  end
end
