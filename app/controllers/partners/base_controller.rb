require 'ostruct'
require "csv"

module Partners
  class BaseController < ApplicationController
    layout 'partner'

    # Partner dashboard should not inherit customer-workspace behavior.
    skip_before_action :authenticate_user!
    skip_before_action :set_active_workspace
    skip_before_action :set_unread_insights
    skip_before_action :redirect_restricted_users!
    skip_before_action :ensure_workspace_ready!

    before_action :require_partner_authentication

    helper_method :next_payout_date, :previous_month_range

    private

    def next_payout_date
      date = Date.today.change(day: 15)
      date = date.next_month if Date.today >= date
      date -= 1.day while date.saturday? || date.sunday?
      date
    end

    def previous_month_range
      Date.today.prev_month.beginning_of_month..Date.today.prev_month.end_of_month
    end

    def require_partner_authentication
      unless user_signed_in? && current_user.partner?
        redirect_to new_partner_session_path, alert: 'Please sign in as a partner.'
      end
    end

    # Build a pseudo payout object for a given user & month
    # id: "next" or "future"
    # month: Date (the month being covered)
    # label: display label (e.g., "Upcoming Payout")
    def build_pseudo_payout_for(user:, id:, month:, label:)
      start_date  = month.beginning_of_month
      end_date    = month.end_of_month
      payout_date = calculate_payout_date_for_month(month.next_month) # pay on 15th next month (or prior Fri)

      charges = user.affiliate_charges.where(payout_id: nil, created_at: start_date..end_date)
      amount  = charges.sum(:commission) || 0

      OpenStruct.new(
        id: id,
        label: label,
        amount: amount,
        start_date: start_date,
        end_date: end_date,
        payout_date: payout_date,
        charges: charges,
        is_pseudo: true
      )
    end

    # 15th of (year, month), but if Sat/Sun use prior Friday
    def calculate_payout_date_for_month(month)
      date = month.change(day: 15)
      date -= 1 while date.saturday? || date.sunday?
      date
    end

    # Send CSV with sane headers
    def send_csv(filename:, rows:, headers:)
      csv = CSV.generate do |out|
        out << headers
        rows.each { |r| out << r }
      end

      send_data csv,
        filename: sanitized_filename(filename),
        disposition: "attachment",
        type: "text/csv; charset=utf-8"
    end

    # Convenience: format money (cents -> $x.xx)
    def fmt_money_cents(cents)
      sprintf("%.2f", (cents.to_i / 100.0))
    end

    # Convenience: mm/dd/yyyy (or change to your preferred)
    def fmt_date(dt)
      return "" unless dt
      dt.in_time_zone.strftime("%b %-d, %Y")
    end

    def sanitized_filename(name)
      base = name.to_s.gsub(/[^\w\.\-]+/, "_")
      base = "export.csv" if base.blank?
      base.ends_with?(".csv") ? base : "#{base}.csv"
    end
  end
end
