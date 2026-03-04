# app/controllers/partners/dashboard_controller.rb
module Partners
  class DashboardController < BaseController
    respond_to :html, :csv, only: [:transactions]

    def index
      range = time_range

      # ----- Links / referral URL -----
      @links        = current_user.links
      @primary_link = @links.first
      @referral_url = @primary_link ? referral_redirect_url(code: @primary_link.code) : nil

      # ----- Charges (affiliate "transactions") -----
      charges_scope = Charge.where(affiliate_id: current_user.id, created_at: range)
      @earnings_total_cents = charges_scope.sum(:commission).to_i
      @earnings_total       = @earnings_total_cents / 100.0
      @sales_total          = charges_scope.count

      # ----- Clicks / Leads -----
      link_ids      = @links.select(:id)
      @clicks_total = LinkClick.human.where(link_id: link_ids, created_at: range).count
      @leads_total  = User.where(referred_by_link_id: link_ids, created_at: range).count

      # ----- Payouts card (pseudo + recent real) -----
      last_month    = Date.today.prev_month
      current_month = Date.today

      pseudo_next   = build_pseudo_payout_for(user: current_user, id: "next",   month: last_month,    label: "Upcoming Payout")
      pseudo_future = build_pseudo_payout_for(user: current_user, id: "future", month: current_month, label: "Upcoming Payout")

      pseudo_items = []

      pseudo_items << {
        amount_cents: pseudo_next.amount.to_i,
        date:         pseudo_next.payout_date,
        status:       pseudo_next.label,
        start_date:   pseudo_next.start_date,
        end_date:     pseudo_next.end_date,
        kind:         :pseudo
      }

      if pseudo_future.amount.to_i.positive?
        pseudo_items << {
          amount_cents: pseudo_future.amount.to_i,
          date:         pseudo_future.payout_date,
          status:       pseudo_future.label,
          start_date:   pseudo_future.start_date,
          end_date:     pseudo_future.end_date,
          kind:         :pseudo
        }
      end

      real_recent = Payout.where(user_id: current_user.id)
                          .order(Arel.sql("COALESCE(paid_at, created_at) DESC"))
                          .limit(4)
                          .map { |p|
                            {
                              amount_cents: p.amount,
                              date:         (p.paid_at || p.created_at),
                              status:       p.status.to_s.humanize,
                              start_date:   p.start_date,
                              end_date:     p.end_date,
                              kind:         :real
                            }
                          }

      # pseudo first, then real; cap to 4 items for the card
      @payouts_card_items = (pseudo_items.reverse! + real_recent).first(4)

      # ----- Recent earnings table (latest 10 charges) -----
      recent_charges = Charge.where(affiliate_id: current_user.id)
                             .order(created_at: :desc)
                             .limit(10)

      customers    = User.where(id: recent_charges.map(&:customer_id).compact).index_by(&:id)
      ref_link_ids = customers.values.map(&:referred_by_link_id).compact
      links_by_id  = Link.where(id: ref_link_ids).index_by(&:id)
      subs_by_id   = Subscription.where(id: recent_charges.map(&:subscription_id).compact).index_by(&:id)

      @recent_earnings = recent_charges.map do |c|
        customer = customers[c.customer_id]
        rlink    = links_by_id[customer&.referred_by_link_id]
        interval = subs_by_id[c.subscription_id]&.interval
        {
          date:   c.created_at.to_date,
          type:   (interval.present? ? interval.capitalize : "Transaction"),
          link:   (rlink&.code || "—"),
          sale:   c.amount.to_i / 100.0,
          earn:   c.commission.to_i / 100.0,
          status: c.payout_id.present? ? "Paid" : "Pending"
        }
      end

      # --- 30-day series for sparklines ---
      from      = 29.days.ago.to_date
      to        = Time.zone.today
      days      = (from..to).to_a
      range_30d = from.beginning_of_day..to.end_of_day

      # Earnings: sum of commission (in dollars) per day
      earn_by_day_cents = charges_scope.group("DATE(created_at)").sum(:commission) # {date=>cents}
      @earnings_points  = days.map { |d| earn_by_day_cents[d]&.to_i.to_f / 100.0 }

      # Clicks: count per day
      clicks_by_day = LinkClick.human.where(link_id: link_ids, created_at: range_30d)
                               .group("DATE(created_at)").count
      @clicks_points = days.map { |d| clicks_by_day[d].to_i }

      # Leads: new referred users per day
      leads_by_day = User.where(referred_by_link_id: link_ids, created_at: range_30d)
                         .group("DATE(created_at)").count
      @leads_points = days.map { |d| leads_by_day[d].to_i }

      # Sales: orders per day (count of charges)
      sales_by_day = charges_scope.group("DATE(created_at)").count
      @sales_points = days.map { |d| sales_by_day[d].to_i }

      # Trials = subscriptions created in the period (every sub starts with a trial)
      trial_user_ids = User.where(referred_by_link_id: link_ids).select(:id)
      trials_scope   = Subscription.where(user_id: trial_user_ids, created_at: range_30d)

      @trials_total  = trials_scope.count
      trials_by_day  = trials_scope.group("DATE(created_at)").count
      @trials_points = days.map { |d| trials_by_day[d].to_i }

    end

    def resources
      scope = PartnerResource.ordered
      @resources_by_category = scope.where(resource_type: "file").group_by(&:category)
      @brand_colors = scope.where(resource_type: "color", category: "brand_colors")
    end

    def transactions
      @charges = Charge
        .where(affiliate_id: current_user.id)
        .includes(:subscription, :customer, :payout)
        .order(created_at: :desc)

      @total_count            = @charges.size
      @total_gross_cents      = @charges.sum(:amount).to_i
      @total_commission_cents = @charges.sum(:commission).to_i

      respond_to do |format|
        format.html
        format.csv do
          require "csv"
          headers = %w[id date customer plan amount commission status payout_date]
          rows = @charges.map do |c|
            status =
              if c.payout_id.nil? then "pending"
              else "paid"
              end

              payout_date =
                if c.payout
                  (c.payout.paid_at || c.payout.created_at)&.in_time_zone&.strftime("%Y-%m-%d")
                else
                  nil
                end

            [
              c.id,
              c.created_at.in_time_zone.strftime("%Y-%m-%d"),
              c.customer&.email,
              c.subscription&.interval&.capitalize,
              format("%.2f", c.amount.to_i / 100.0),
              format("%.2f", c.commission.to_i / 100.0),
              status,
              payout_date
            ]
          end

          csv = CSV.generate do |out|
            out << headers
            rows.each { |r| out << r }
          end

          send_data csv,
            filename: "transactions-#{Time.zone.today}.csv",
            disposition: "attachment",
            type: "text/csv; charset=utf-8"
        end
      end
    end



    private

    # Defaults to last 30 days; accepts params[:from], params[:to] (e.g., "2025-11-01")
    def time_range
      from = params[:from].presence ? Time.zone.parse(params[:from]) : 30.days.ago
      to   = params[:to].presence   ? Time.zone.parse(params[:to])   : Time.current
      from..to
    end
  end
end
