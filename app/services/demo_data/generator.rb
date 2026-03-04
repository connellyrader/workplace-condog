# app/services/demo_data/generator.rb
# frozen_string_literal: true

require "zlib"

module DemoData
  class Generator
    DEMO_WORKSPACE_NAME = "Demo Workspace".freeze

    # Integration identification (your schema: kind + slack_team_id unique per workspace)
    DEMO_INTEGRATION_KIND = "slack".freeze
    DEMO_TEAM_ID_PREFIX   = "TDEMO".freeze

    DEMO_MODEL_TEST_NAME = "Demo Workspace Generator".freeze
    DEMO_MODEL_TEST_TYPE = "demo".freeze

    # Users/groups/channels
    DEMO_USER_COUNT = 50

    FUNCTIONS  = %w[Engineering Sales Marketing Support Product Operations].freeze
    GEOS       = ["US East", "US West", "EMEA", "APAC"].freeze
    SENIORITY  = ["IC", "Manager", "Director", "Executive"].freeze
    TENURE     = ["<6 months", "6-24 months", "2-5 years", "5+ years"].freeze

    # Message volume per function channel per day
    MESSAGES_PER_FUNCTION_RANGE = (40..60)

    # Detections per message
    DETECTIONS_PER_MESSAGE_RANGE = (1..4)

    # Force detections to be "strong" (you filter by logit_margin >= threshold)
    LOGIT_MARGIN_BASE   = 2.25
    LOGIT_MARGIN_JITTER = 1.25

    LOGIT_SCORE_BASE   = 3.0
    LOGIT_SCORE_JITTER = 1.5

    # Long-term function trends (probability of positive detection)
    # base: starting positivity; trend: daily drift; noise: day-level randomness
    FUNCTION_PROFILES = {
      "Engineering" => { base: 0.82, trend:  0.0000, noise: 0.03 },
      "Sales"       => { base: 0.60, trend:  0.0007, noise: 0.04 }, # improving
      "Marketing"   => { base: 0.72, trend:  0.0001, noise: 0.06 }, # more variance
      "Support"     => { base: 0.62, trend: -0.0006, noise: 0.05 }, # declining
      "Product"     => { base: 0.74, trend:  0.0000, noise: 0.04 },
      "Operations"  => { base: 0.70, trend:  0.0000, noise: 0.03 }
    }.freeze

    # Metric-specific base positivity (higher = more positive signals; lower = more negative)
    # Blended with function profile for varied scores across metrics
    METRIC_PROFILES = {
      "Employee Engagement" => 0.78,
      "Alignment"           => 0.72,
      "Psychological Safety"=> 0.68,
      "Execution Risk"      => 0.52,  # lower = more negative (risk signals)
      "Conflict"            => 0.48,
      "Burnout"             => 0.42   # lowest = most negative
    }.freeze

    # Small modifiers (keep subtle; makes slices feel real without contradicting channels)
    GEO_MOD = {
      "US East" =>  0.01,
      "US West" =>  0.00,
      "EMEA"    => -0.01,
      "APAC"    => -0.015
    }.freeze

    SENIORITY_MOD = {
      "IC"        =>  0.00,
      "Manager"   =>  0.01,
      "Director"  =>  0.015,
      "Executive" =>  0.02
    }.freeze

    TENURE_MOD = {
      "<6 months"    => -0.02,
      "6-24 months"  => -0.005,
      "2-5 years"    =>  0.005,
      "5+ years"     =>  0.01
    }.freeze

    TREND_ANCHOR_DATE = Date.new(2025, 1, 1)

    # Category sampling: build a stable “pool” per function so it looks coherent
    # 80% from function pool, 20% from global
    FUNCTION_POOL_SIZE = 160
    FUNCTION_POOL_PCT  = 0.80

    def initialize(date:)
      @date = date
    end

    def run!
      ws          = ensure_demo_workspace!
      ensure_demo_workspace_owner!(ws)
      ensure_demo_subscription!(ws)
      integration = ensure_demo_integration!(ws)

      # If already created demo messages for this day, skip (idempotent)
      if demo_messages_exist_for_day?(integration, @date)
        Rails.logger.info "[DemoData] already generated for #{@date}; skipping"
        return
      end

      demo_users = ensure_demo_integration_users!(integration)

      # Assign stable attributes to users (function, geo, seniority, tenure)
      user_attrs = assign_user_attributes(demo_users)

      # Ensure segmentation groups exist + memberships (Function/Geo/Seniority/Tenure)
      groups_by_name = ensure_segmentation_groups!(ws)
      ensure_group_memberships!(groups_by_name, user_attrs)

      # Ensure Everyone group exists and contains all demo members.
      everyone = ensure_everyone_group!(ws)
      ensure_everyone_membership!(everyone, demo_users)

      # Channels per function (6 channels)
      channels_by_function = ensure_function_channels!(integration)

      # Channel memberships: put each user in their function channel
      ensure_channel_memberships!(integration, channels_by_function, user_attrs)

      model_test = ensure_demo_model_test!(ws, integration)
      air        = create_demo_async_inference_result!(model_test)

      # Preload signal categories & submetric->metric mapping (for setting detection columns)
      sc_rows = SignalCategory.select(:id, :submetric_id).to_a
      raise "No SignalCategory rows found; cannot generate demo detections." if sc_rows.empty?

      sc_ids = sc_rows.map(&:id)
      submetric_to_metric = Submetric.pluck(:id, :metric_id).to_h
      metric_id_to_name = Metric.pluck(:id, :name).to_h

      # Build stable per-function pools (no domain assumptions required)
      function_pools = build_function_pools(sc_ids)

      generate_day!(
        integration: integration,
        user_attrs: user_attrs,
        channels_by_function: channels_by_function,
        model_test: model_test,
        async_inference_result: air,
        sc_rows_by_id: sc_rows.index_by(&:id),
        submetric_to_metric: submetric_to_metric,
        metric_id_to_name: metric_id_to_name,
        sc_ids: sc_ids,
        function_pools: function_pools
      )
    end

    private

    # ---------------------------
    # Ensure base demo entities
    # ---------------------------

    def ensure_demo_workspace!
      # NOTE: This can run from a nightly job. Make creation race-safe.
      Workspace.find_by(name: DEMO_WORKSPACE_NAME) || begin
        owner = demo_owner_user
        raise "Cannot create demo workspace: no users exist to set as owner_id" unless owner

        Workspace.create!(name: DEMO_WORKSPACE_NAME, owner_id: owner.id)
      rescue ActiveRecord::RecordNotUnique
        # Another process beat us; load the winner.
        Workspace.find_by!(name: DEMO_WORKSPACE_NAME)
      end
    end

    def ensure_demo_workspace_owner!(ws)
      owner = ws.owner

      if owner.nil?
        owner = demo_owner_user
        raise "Cannot assign demo workspace owner: no users exist" unless owner

        ws.update!(owner_id: owner.id)
      end

      WorkspaceUser.find_or_create_by!(workspace_id: ws.id, user_id: owner.id) do |wu|
        wu.role = "owner"
        wu.is_owner = true
      end
    end

    def ensure_demo_subscription!(ws)
      has_subscription = ws.subscriptions.where(status: %w[active trialing]).exists?
      return if has_subscription

      owner = ws.owner || demo_owner_user
      raise "Cannot create demo subscription: no users exist" unless owner

      Subscription.create!(
        workspace_id: ws.id,
        user_id: owner.id,
        stripe_subscription_id: "demo-sub-#{ws.id}",
        status: "active",
        started_on: @date,
        expires_on: @date + 1.year,
        amount: 0,
        interval: "year"
      )
    end

    def ensure_demo_model_test!(_ws, integration)
      # ModelTest is keyed to an integration; it does not have workspace_id in schema.
      # It DOES require model + signal_category.
      model = Model.order(:id).first
      raise "No Model rows found; cannot create demo model_test." unless model

      sc = SignalCategory.order(:id).first
      raise "No SignalCategory rows found; cannot create demo model_test." unless sc

      ModelTest.find_or_create_by!(
        test_type: DEMO_MODEL_TEST_TYPE,
        name: DEMO_MODEL_TEST_NAME,
        integration_id: integration.id,
        model_id: model.id,
        signal_category_id: sc.id
      ) do |mt|
        mt.description = "Demo workspace data generator"
      end
    end

    def demo_owner_user
      admin = User.where(admin: true).order(:id).first
      return admin if admin

      User.order(:id).first
    end

    def ensure_demo_integration!(ws)
      slack_team_id = "#{DEMO_TEAM_ID_PREFIX}-WS#{ws.id}"

      integ = Integration.find_by(workspace_id: ws.id, slack_team_id: slack_team_id)
      return integ if integ

      Integration.create!(
        workspace_id: ws.id,
        kind: DEMO_INTEGRATION_KIND,
        slack_team_id: slack_team_id,
        name: "Demo Integration",
        domain: "demo",

        # Keep gating open
        analyze_complete: true,
        days_analyzed: 365,

        # Let your app defaults/enums handle these safely
        # sync_status: default "queued"
        # setup_status: default "queued"
        setup_progress: 100
      )

    end

    def ensure_demo_integration_users!(integration)
      existing = IntegrationUser.where(integration_id: integration.id).to_a
      return existing if existing.size >= DEMO_USER_COUNT

      needed = DEMO_USER_COUNT - existing.size
      now = Time.current

      rows = needed.times.map do |i|
        idx = existing.size + i + 1
        {
          integration_id: integration.id,
          slack_user_id: "UDEMO#{idx.to_s.rjust(6, "0")}", # required + unique per integration
          role: "member",
          display_name: "Demo#{idx}",
          real_name: "Demo User #{idx}",
          email: "demo.user#{idx}@example.com",
          active: true,
          is_bot: false,
          created_at: now,
          updated_at: now
        }
      end

      IntegrationUser.insert_all!(rows) if rows.any?
      IntegrationUser.where(integration_id: integration.id).to_a
    end

    def create_demo_async_inference_result!(model_test)
      AsyncInferenceResult.create!(
        model_test_id: model_test.id,
        status: "completed",
        inference_type: "demo",
        provider: "demo",
        completed_at: Time.current,
        duration: 0.0
      )
    end

    def demo_messages_exist_for_day?(integration, day)
      Message
        .where(integration_id: integration.id)
        .where("posted_at >= ? AND posted_at <= ?", day.beginning_of_day, day.end_of_day)
        .where(subtype: "demo")
        .exists?
    end

    # ---------------------------
    # Segmentation groups
    # ---------------------------

    def ensure_segmentation_groups!(ws)
      names = []
      FUNCTIONS.each { |x| names << "Function: #{x}" }
      GEOS.each      { |x| names << "Geo: #{x}" }
      SENIORITY.each { |x| names << "Seniority: #{x}" }
      TENURE.each    { |x| names << "Tenure: #{x}" }

      groups = names.map do |name|
        Group.find_or_create_by!(workspace_id: ws.id, name: name)
      end

      groups.index_by(&:name)
    end

    def ensure_everyone_group!(ws)
      Group.find_or_create_by!(workspace_id: ws.id, name: "Everyone")
    end

    def ensure_everyone_membership!(everyone_group, demo_users)
      now = Time.current

      rows = demo_users.map do |iu|
        {
          group_id: everyone_group.id,
          integration_user_id: iu.id,
          created_at: now,
          updated_at: now
        }
      end

      GroupMember.upsert_all(
        rows,
        unique_by: "index_group_members_on_group_id_and_integration_user_id"
      ) if rows.any?
    end

    # Deterministic assignment (stable across runs)
    def assign_user_attributes(demo_users)
      # Spread people across dimensions in a repeatable way
      rng = Random.new(12345)

      demo_users.sort_by(&:id).map.with_index do |iu, idx|
        fn = FUNCTIONS[idx % FUNCTIONS.size]
        geo = GEOS[(idx / FUNCTIONS.size) % GEOS.size]
        sen = SENIORITY[(idx / (FUNCTIONS.size * GEOS.size)) % SENIORITY.size]
        ten = TENURE[(idx / (FUNCTIONS.size * GEOS.size * SENIORITY.size)) % TENURE.size]

        {
          iu: iu,
          function: fn,
          geo: geo,
          seniority: sen,
          tenure: ten,
          seed: Zlib.crc32("demo:user:#{iu.id}:#{iu.slack_user_id}") ^ rng.rand(1..1_000_000)
        }
      end
    end

    def ensure_group_memberships!(groups_by_name, user_attrs)
      now = Time.current
      rows = []

      user_attrs.each do |ua|
        iu_id = ua[:iu].id

        [
          "Function: #{ua[:function]}",
          "Geo: #{ua[:geo]}",
          "Seniority: #{ua[:seniority]}",
          "Tenure: #{ua[:tenure]}"
        ].each do |gname|
          g = groups_by_name[gname]
          next unless g

          rows << {
            group_id: g.id,
            integration_user_id: iu_id,
            created_at: now,
            updated_at: now
          }
        end
      end

      GroupMember.upsert_all(
        rows,
        unique_by: "index_group_members_on_group_id_and_integration_user_id"
      ) if rows.any?
    end

    # ---------------------------
    # Function channels + memberships
    # ---------------------------

    def ensure_function_channels!(integration)
      out = {}

      FUNCTIONS.each do |fn|
        ext  = "CDEMO-FN-#{fn.upcase}"
        name = "demo-#{fn.parameterize}"

        ch = Channel.find_by(integration_id: integration.id, external_channel_id: ext)
        ch ||= Channel.create!(
          integration_id: integration.id,
          external_channel_id: ext,
          name: name,
          kind: "public_channel",
          is_private: false,
          is_archived: false,
          created_unix: Time.current.to_i
        )

        out[fn] = ch
      end

      out
    end

    def ensure_channel_memberships!(integration, channels_by_function, user_attrs)
      now = Time.current
      rows = []

      user_attrs.each do |ua|
        iu_id = ua[:iu].id
        fn    = ua[:function]
        ch    = channels_by_function[fn]
        next unless ch

        rows << {
          integration_id: integration.id,
          channel_id: ch.id,
          integration_user_id: iu_id,
          joined_at: now,
          created_at: now,
          updated_at: now
        }
      end

      ChannelMembership.upsert_all(
        rows,
        unique_by: "idx_on_channel_id_integration_user_id_b522800b12"
      ) if rows.any?

    end

    # ---------------------------
    # Category pools
    # ---------------------------

    def build_function_pools(sc_ids)
      pools = {}

      FUNCTIONS.each do |fn|
        seed = Zlib.crc32("demo:function_pool:#{fn}")
        rng  = Random.new(seed)
        pools[fn] = sc_ids.sample(FUNCTION_POOL_SIZE, random: rng)
      end

      pools
    end

    # ---------------------------
    # Day generation
    # ---------------------------

    def generate_day!(integration:, user_attrs:, channels_by_function:, model_test:, async_inference_result:,
                      sc_rows_by_id:, submetric_to_metric:, metric_id_to_name:, sc_ids:, function_pools:)
      now = Time.current
      day_start = @date.in_time_zone.beginning_of_day
      day_end   = @date.in_time_zone.end_of_day

      # Global RNG for the day (deterministic)
      global_seed = Zlib.crc32("demo:day:#{integration.id}:#{@date}")
      rng_global  = Random.new(global_seed)

      # Group users by function for message generation
      users_by_function = user_attrs.group_by { |ua| ua[:function] }

      message_rows = []

      FUNCTIONS.each do |fn|
        ch = channels_by_function[fn]
        next unless ch

        members = users_by_function[fn] || []
        next if members.empty?

        msg_count = rng_global.rand(MESSAGES_PER_FUNCTION_RANGE)

        msg_count.times do |i|
          ua = members.sample(random: rng_global)
          iu_id = ua[:iu].id

          posted_at = day_start + rng_global.rand(0..86_399).seconds

          # slack_ts must exist and be unique per channel_id.
          # Use posted_at ms + a deterministic suffix so reruns collide safely.
          suffix  = (Zlib.crc32("demo:#{@date}:#{fn}:#{iu_id}:#{i}") % 10_000)
          slack_ts = "#{(posted_at.to_f * 1000).to_i}.#{suffix.to_s.rjust(4, "0")}"

          message_rows << {
            integration_id: integration.id,
            channel_id: ch.id,
            integration_user_id: iu_id,
            slack_ts: slack_ts,
            posted_at: posted_at,
            text: "",

            processed: true,
            processed_at: posted_at + 5.seconds,

            subtype: "demo",
            deleted: false,
            references_processed: true,
            references_processed_at: posted_at + 5.seconds,

            created_at: now,
            updated_at: now
          }
        end
      end

      ActiveRecord::Base.transaction do
        # Unique constraint on messages: [channel_id, slack_ts]
        Message.upsert_all(
          message_rows,
          unique_by: "index_messages_on_channel_id_and_slack_ts"
        ) if message_rows.any?

        inserted_messages =
          Message
            .where(integration_id: integration.id, subtype: "demo")
            .where("posted_at >= ? AND posted_at <= ?", day_start, day_end)
            .select(:id, :channel_id, :integration_user_id, :posted_at)

      Rails.logger.info "[DemoData] messages inserted=#{inserted_messages.size} date=#{@date}"

      # quick lookups
      channel_to_function = channels_by_function.transform_values(&:id).invert # channel_id => function
      ua_by_iu_id = user_attrs.map { |ua| [ua[:iu].id, ua] }.to_h

      # Avoid per-row DB lookups for SignalSubcategory.
      # { signal_category_id => [signal_subcategory_id, ...] }
      scid_to_subcategory_ids =
        SignalSubcategory
          .pluck(:signal_category_id, :id)
          .group_by(&:first)
          .transform_values { |pairs| pairs.map(&:last) }

      detection_rows = []
      detection_inserted = 0

      flush_detections = lambda do
        next if detection_rows.empty?

        Detection.upsert_all(
          detection_rows,
          unique_by: "index_detections_on_msg_sc_mt_polarity"
        )
        detection_inserted += detection_rows.size
        detection_rows.clear
      end

      inserted_messages.find_each(batch_size: 500) do |m|
        fn = channel_to_function[m.channel_id] || "Engineering"
        ua = ua_by_iu_id[m.integration_user_id]
        next unless ua

        prof = FUNCTION_PROFILES[fn] || { base: 0.65, trend: 0.0, noise: 0.05 }

        day_index = (@date - TREND_ANCHOR_DATE).to_i

        # p_positive = function trend + small modifiers + noise
        p = prof[:base].to_f +
            prof[:trend].to_f * day_index +
            GEO_MOD[ua[:geo]].to_f +
            SENIORITY_MOD[ua[:seniority]].to_f +
            TENURE_MOD[ua[:tenure]].to_f +
            rand_normal(rng_global, mean: 0.0, stddev: prof[:noise].to_f)

        p_positive = p.clamp(0.02, 0.98)

        k = rng_global.rand(DETECTIONS_PER_MESSAGE_RANGE)

        fn_pool = function_pools[fn] || []
        from_pool = (k * FUNCTION_POOL_PCT).round
        from_pool = [[from_pool, 0].max, k].min
        from_global = k - from_pool

        sampled = []
        sampled.concat(fn_pool.sample(from_pool, random: rng_global)) if from_pool > 0 && fn_pool.any?
        sampled.concat(sc_ids.sample(from_global, random: rng_global)) if from_global > 0
        sampled = sampled.compact.uniq
        next if sampled.empty?

        sampled.each do |scid|
          sc = sc_rows_by_id[scid]
          next unless sc

          submetric_id = sc.submetric_id
          metric_id    = submetric_to_metric[submetric_id]
          metric_name  = metric_id_to_name[metric_id].to_s

          # Blend function profile with metric profile for varied scores across metrics
          metric_base = METRIC_PROFILES[metric_name] || 0.65
          p_blended   = (p_positive * 0.5) + (metric_base * 0.5)
          p_blended   = p_blended.clamp(0.02, 0.98)

          positive = rng_global.rand < p_blended
          polarity = positive ? "positive" : "negative"
          score    = positive ? 1 : 0

          logit_margin = LOGIT_MARGIN_BASE + rng_global.rand * LOGIT_MARGIN_JITTER
          logit_score = LOGIT_SCORE_BASE + rng_global.rand * LOGIT_SCORE_JITTER

          # Optional: pick a signal_subcategory under this category for realism (no DB call)
          ss_ids = scid_to_subcategory_ids[scid] || []
          ss_id  = ss_ids.empty? ? nil : ss_ids[rng_global.rand(0...ss_ids.size)]

          detection_rows << {
            message_id: m.id,
            signal_category_id: scid,
            model_test_id: model_test.id,
            async_inference_result_id: async_inference_result.id,

            polarity: polarity,
            score: score,
            logit_margin: logit_margin,
            logit_score: logit_score,

            metric_id: metric_id,
            submetric_id: submetric_id,
            signal_subcategory_id: ss_id,

            full_output: {},

            created_at: now,
            updated_at: now
          }
        end

        flush_detections.call if detection_rows.size >= 5_000
      end

      flush_detections.call

      Rails.logger.info "[DemoData] detections inserted=#{detection_inserted} date=#{@date}"
      end
    end

    # Box–Muller normal noise
    def rand_normal(rng, mean:, stddev:)
      u1 = [rng.rand, 1e-9].max
      u2 = rng.rand
      z0 = Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math::PI * u2)
      mean + z0 * stddev
    end
  end
end
