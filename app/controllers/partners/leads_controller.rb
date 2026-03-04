# app/controllers/partners/referrals_controller.rb
module Partners
  class LeadsController < Partners::BaseController
    respond_to :html, :csv, only: [:index]

    def index
      # Filters
      # - q: name/email substring
      # - status: lead|trial|active|canceled (derived from latest subscription)
      # - link_id: restrict to a specific referral link
      # - from/to: signup date bounds (YYYY-MM-DD)
      @q       = params[:q].to_s.strip
      @status  = params[:status].to_s.strip
      @link_id = params[:link_id].to_s.strip

      from = params[:from].presence && Time.zone.parse(params[:from]) rescue nil
      to   = params[:to].presence   && Time.zone.parse(params[:to])   rescue nil

      # Base: users referred by any of the current partner's links
      link_ids = current_user.links.select(:id)
      scope = User.where(referred_by_link_id: link_ids)

      scope = scope.where(referred_by_link_id: @link_id) if @link_id.present?
      scope = scope.where("users.created_at >= ?", from.beginning_of_day) if from
      scope = scope.where("users.created_at <= ?", to.end_of_day) if to

      if @q.present?
        q = "%#{@q}%"
        scope = scope.where(
          "users.email ILIKE ? OR users.first_name ILIKE ? OR users.last_name ILIKE ?",
          q, q, q
        )
      end

      # Preload last subscription data without N+1
      scope = scope.includes(:subscriptions)

      # Apply status filter (based on latest subscription)
      if @status.present?
        scope = scope.select { |u| status_bucket_for(u) == @status }

        # When we switch to Array (ruby select), we lose kaminari's AR relation.
        # Wrap it for pagination.
        @referrals = Kaminari.paginate_array(scope).page(params[:page]).per(50)
      else
        @referrals = scope.order(created_at: :desc).page(params[:page]).per(50)
      end

      # Map referral link IDs -> codes (to show which link converted)
      @link_code_by_id = Link.where(id: @referrals.map(&:referred_by_link_id).compact)
                             .pluck(:id, :code).to_h

      respond_to do |format|
        format.html
        format.csv do
          require "csv"
          headers = %w[
            id
            name
            email
            referral_link_code
            signed_up
            status
            plan
            amount
            last_active
          ]

          rows = @referrals.map do |u|
            sub = u.subscriptions.max_by(&:created_at)
            name =
              if u.respond_to?(:full_name) && u.full_name.present?
                u.full_name
              else
                [u.try(:first_name), u.try(:last_name)].compact.join(" ")
              end

            status = status_label_for(u)

            plan   = sub&.interval&.capitalize
            amount = sub&.amount ? format("%.2f", sub.amount.to_i / 100.0) : ""
            last_active = sub&.updated_at&.in_time_zone&.strftime("%Y-%m-%d") || ""

            [
              u.id,
              name.presence || "",
              u.email,
              @link_code_by_id[u.referred_by_link_id].to_s,
              u.created_at.in_time_zone.strftime("%Y-%m-%d"),
              status,
              plan.to_s,
              amount,
              last_active
            ]
          end

          csv = CSV.generate do |out|
            out << headers
            rows.each { |r| out << r }
          end

          send_data csv,
            filename: "leads-#{Time.zone.today}.csv",
            disposition: "attachment",
            type: "text/csv; charset=utf-8"
        end
      end
    end

    def show
      # Ensure the lead belongs to this partner
      @lead = User
        .where(referred_by_link_id: current_user.links.select(:id))
        .includes(:subscriptions)
        .find(params[:id])

      @subscription = @lead.subscriptions.max_by(&:created_at)
      @link         = Link.find_by(id: @lead.referred_by_link_id)

      @charges = Charge
        .where(affiliate_id: current_user.id, customer_id: @lead.id)
        .includes(:subscription, :payout)
        .order(created_at: :desc)
        .limit(50)
    end

    private

    def status_bucket_for(user)
      sub = user.subscriptions.max_by(&:created_at)
      return "lead" unless sub&.status.present?

      s = sub.status.to_s
      return "trial" if s == "trialing"
      return "active" if s == "active"
      return "canceled" if %w[canceled cancelled expired past_due unpaid].include?(s)

      "lead"
    end

    def status_label_for(user)
      sub = user.subscriptions.max_by(&:created_at)
      return "Lead" unless sub&.status.present?
      sub.status.to_s.capitalize
    end
  end
end
