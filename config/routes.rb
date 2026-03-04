Rails.application.routes.draw do
  # Error pages (used by config.exceptions_app)
  get "/404", to: "errors#not_found"
  get "/500", to: "errors#internal_server_error"

  mount ActionCable.server => "/cable"

  # Component catalog (development only)
  mount Lookbook::Engine, at: "/lookbook" if Rails.env.development?

  # ====== SLACK SSO & PROFILE ======
  devise_for :users, controllers: {
  omniauth_callbacks: "users/omniauth_callbacks",
  registrations:      "users/registrations"
  }
  
  # Admin namespace with masquerade
  namespace :admin do
    resources :users, only: [:index]
    post '/masquerade/:id', to: 'masquerades#create', as: :masquerade_user
    delete '/masquerade', to: 'masquerades#destroy', as: :stop_masquerade
  end

  # Public Trust Center (directory + docs)

  # Trust subdomain
  constraints(host: "trust.workplace.io") do
    get "/",     to: "trust_center#index", as: :trust_home_hosted
    get "/:slug", to: "trust_center#show", as: :trust_doc_hosted
  end

  # /trust directory (optional fallback)
  get "/trust",       to: "trust_center#index", as: :trust_center
  get "/trust/:slug", to: "trust_center#show",  as: :trust_doc

  # ====== INVITES (token-based; no active workspace required) ======
  # "Pending" invite flow for logged-in users (no email token required)
  get  "/invites/pending",        to: "invites#pending",        as: :pending_invites
  post "/invites/pending/:id/accept",  to: "invites#accept_pending",  as: :accept_pending_invite
  post "/invites/pending/:id/decline", to: "invites#decline_pending", as: :decline_pending_invite

  get "/invites/:token", to: "invites#show", as: :invite
  post "/invites/:token/accept", to: "invites#accept", as: :accept_invite
  post "/invites/:token/decline", to: "invites#decline", as: :decline_invite


  root 'home#root'

  # Development-only: fake login without password (e.g. /dev/login?email=demo@example.com)
  get "/dev/login", to: "dev#login", as: :dev_login if Rails.env.development?

  get '/not_lucas', to: 'dashboard#not_lucas'

  # Teams OAuth connect for ingestion
  get "teams/connect",                      to: "teams_oauth#start",                  as: :teams_connect
  get "teams/oauth/callback",               to: "teams_oauth#callback",               as: :teams_oauth_callback
  get "teams/oauth/admin_consent_callback", to: "teams_oauth#admin_consent_callback", as: :teams_oauth_admin_consent_callback
  get "teams/oauth/admin_intro",            to: "teams_oauth#admin_intro",            as: :teams_oauth_admin_intro


  # ====== SLACK OAUTH For connecting slack team for ingestion ======
  get 'slack/history/start',    to: 'slack_oauth#start'
  get 'slack/history/callback', to: 'slack_oauth#callback'

  # ====== SLACK EVENTS For live messages ======
  post 'slack/event', to: 'webhooks/slack_events#receive'

  get  '/start',       to: 'onboarding#start',       as: :start
    get "/onboarding/setup_status", to: "onboarding#setup_status", as: :onboarding_setup_status
    get "/onboarding/channels",     to: "onboarding#channels",     as: :onboarding_channels
  get  '/plan',        to: 'onboarding#plan',        as: :plan
  post '/start_trial', to: 'onboarding#start_trial', as: :start_trial
  get  '/onboarding/members', to: 'onboarding#members', as: :onboarding_members
  post '/onboarding/groups',  to: 'onboarding#create_group', as: :onboarding_groups
  patch '/onboarding/groups/:id',  to: 'onboarding#update_group',  as: :onboarding_group
  post '/onboarding/selection', to: 'onboarding#save_selection', as: :onboarding_save_selection
  delete '/onboarding/groups/:id', to: 'onboarding#destroy_group'
  get  "/user/integrate", to: "users#user_integrate", as: :user_integrate
  delete "/integrations/:id/connection", to: "settings#disconnect_integration", as: :disconnect_integration
  get  "/user/done",   to: "users#user_done",   as: :user_done

  # ====== DASHBOARD & METRIC PAGES ======
  get 'dashboard', to: 'dashboard#index'
  get 'dashboard/metric/:id', to: 'dashboard#metric', as: :metric
  get 'dashboard/test', to: 'dashboard#test'

  get 'workspace/pending',      to: 'dashboard#workspace_pending', as: :workspace_pending

  # ====== Analyze onboarding experience live stat and detection updates ======
  get "dashboard/detections_random", to: "dashboard#detections_random"
  get "dashboard/detections_stats",  to: "dashboard#detections_stats"
  get "dashboard/analyze_estimate", to: "dashboard#analyze_estimate"



  namespace :ai_chat do
    resources :conversations, only: [:index, :show, :create, :update, :destroy]
    get :sparkline, to: "charts#sparkline"

    get "widgets/sparkline",         to: "widgets#sparkline"
    get "widgets/sparkline_chart",   to: "widgets#sparkline_chart"
    get "widgets/metric_gauge",      to: "widgets#metric_gauge"
    get "widgets/period_comparison", to: "widgets#period_comparison"
    get "widgets/group_comparison",  to: "widgets#group_comparison"
    get "widgets/top_signals",       to: "widgets#top_signals"
    get "widgets/event_impact",      to: "widgets#event_impact"
    get "widgets/aggregate_gauge",   to: "widgets#aggregate_gauge"
  end

  # ====== INSIGHTS ======
  get 'insights', to: 'dashboard#insights'


  # ====== CLARA ======
  get 'clara/docs', to: 'dashboard#docs'


  # ====== SETTINGS ======
  scope path: '/settings' do
    get '/',                       to: 'settings#index',         as: :settings
    patch "/workspace/icon", to: "settings#update_workspace_icon", as: :settings_workspace_icon
    patch  "/workspace",      to: "settings#update_workspace",  as: :settings_workspace
    delete "/workspace",      to: "settings#destroy_workspace"

    get '/integrations',           to: 'settings#integrations'

    get    '/groups',            to: 'settings#groups'
    get    '/groups/:id',        to: 'settings#group',           as: :settings_group
    post   '/groups',            to: 'settings#create_group',    as: :settings_create_group
    patch  '/groups/:id',        to: 'settings#update_group',    as: :settings_update_group
    delete '/groups/:id',        to: 'settings#destroy_group',   as: :settings_destroy_group
    get  '/group_users',         to: 'settings#group_users',     as: :settings_group_users
    delete '/groups/:id/members/:integration_user_id', to: 'settings#remove_group_member', as: :settings_remove_group_member
    get '/users/manage',           to: 'settings#manage_users',  as: :manage_users
    get "/invite_users",           to: "settings#invite_users", as: :settings_invite_users
    post "/invite_users",          to: "settings#send_invites",  as: :settings_send_invites
    post '/users/update_role',     to: 'settings#update_member_role', as: :settings_update_member_role
    post '/users/remove',          to: 'settings#remove_member',      as: :settings_remove_member

    get '/notifications',          to: 'settings#notifications'
    patch '/notifications',  to: 'settings#update_notifications'
    patch '/notifications/permissions', to: 'settings#update_notification_permissions'
    get '/subscription',     to: 'settings#subscription'

    # settings/cookies
    get  "/cookies", to: "settings#cookie_settings", as: :cookie_settings

    # settings/billing
    get    "/billing",                          to: "settings#billing",                       as: :billing
    post   "/billing/add_card",                 to: "settings#billing_add_card",              as: :billing_add_card
    patch  "/billing/default_card",             to: "settings#billing_set_default_card",      as: :billing_set_default_card
    delete "/billing/cards/:payment_method_id", to: "settings#billing_delete_card",           as: :billing_delete_card
    post   "/billing/cancel_subscription",      to: "settings#billing_cancel_subscription",   as: :billing_cancel_subscription
    post   "/billing/pay_now",                  to: "settings#billing_pay_now",               as: :billing_pay_now
    post   "/billing/resume_subscription",      to: "settings#billing_resume_subscription",   as: :billing_resume_subscription
    post   "/billing/switch_to_net30",          to: "settings#billing_switch_to_net30",        as: :billing_switch_to_net30

  end

  # custom routes for devise settings pages
  devise_scope :user do
    # native user login flow
    post "/auth/email/lookup",  to: "email_auth#lookup"
    post "/auth/email/password_sign_in",  to: "email_auth#password_sign_in"
    post "/auth/email/sign_up", to: "email_auth#sign_up"

    # user management
    scope :settings do
      get  'profile', to: 'users/registrations#edit',   as: :settings_profile
      patch 'profile', to: 'users/registrations#update'
      put   'profile', to: 'users/registrations#update'
      delete 'profile', to: 'users/registrations#destroy'
    end
  end


  get 'signals/analyze', to: 'signals#analyze'

  #post "/webhooks/sns/sagemaker_async" => "webhooks/sns#sagemaker_async"

  get 'admin', to: 'admin#index'
  get 'admin_old', to: 'admin_old#index', as: :admin_old
  get 'admin/prompts', to: 'admin/prompts#index', as: :admin_prompts
  get 'admin/prompts/:key', to: 'admin/prompts#show', as: :admin_prompt
  post 'admin/prompts/:key/overview_preview', to: 'admin/prompts#overview_preview', as: :admin_prompt_overview_preview
  post 'admin/prompts/:key/insight_preview', to: 'admin/prompts#insight_preview', as: :admin_prompt_insight_preview

  namespace :admin do
    resources :users, only: [:index]
    resources :partner_resources
    resources :prompt_versions, only: [:create, :update]
    resources :prompt_chat_tests, only: [:index, :show, :create, :destroy]
    resources :prompt_test_runs, only: [:index]

    get "signal_category_audit", to: "signal_category_audit#index"
    get "signal_category_audit/:signal_category_id/details", to: "signal_category_audit#details"

    get  "benchmark_reviews", to: "benchmark_reviews#index"
    post "benchmark_reviews/upsert", to: "benchmark_reviews#upsert", as: :upsert_benchmark_review
    delete "benchmark_reviews/recommendation", to: "benchmark_reviews#destroy", as: :destroy_benchmark_review
    post "benchmark_reviews/mark_scenario_done", to: "benchmark_reviews#mark_scenario_done", as: :mark_scenario_done_benchmark_review
    post "benchmark_reviews/mark_scenario_open", to: "benchmark_reviews#mark_scenario_open", as: :mark_scenario_open_benchmark_review

    get  "insights_studio", to: "insights_studio#index"
    post "insights_studio/run", to: "insights_studio#run", as: :insights_studio_run
    post "insights_studio/run_async", to: "insights_studio#run_async", as: :insights_studio_run_async
    post "insights_studio/rollups", to: "insights_studio#rollups", as: :insights_studio_rollups
    get  "insights_studio/run/:id", to: "insights_studio#show", as: :insights_studio_run_detail
    post "insights_studio/preview", to: "insights_studio#preview"
    post "insights_studio/evidence", to: "insights_studio#evidence"
  end

  get 'models', to: 'admin#models', as: 'admin_models'
  patch 'models/scaling', to: 'model_tests#update_scaling', as: :update_model_scaling
  post 'models/:id/toggle_endpoint', to: 'model_tests#toggle_endpoint', as: :toggle_model_endpoint
  get 'model_tests/:model_test_id/detection_review', to: 'model_tests#detection_review', as: 'detection_review'
  post 'model_tests/detection_review/submit', to: 'model_tests#submit_detection_review', as: 'submit_detection_review'
  resources :model_tests, only: [:index, :show, :create, :update] do
    collection do
      post :create_model
    end
  end


  #### PARTNERS
  post 'partner/event', to: 'webhooks/partner_events#receive'

  devise_scope :user do
    get    '/partner/sign_in',  to: 'partners/sessions#new',     as: :new_partner_session
    post   '/partner/sign_in',  to: 'partners/sessions#create',  as: :partner_session
    delete '/partner/sign_out', to: 'partners/sessions#destroy', as: :destroy_partner_session

    get    '/partner/sign_up',  to: 'partners/registrations#new',    as: :new_partner_registration
    post   '/partner',          to: 'partners/registrations#create', as: :partner_registration
  end

  # Dashboard at /partner using conventional controller
  get '/partners', to: 'partners/dashboard#index'
  get '/partner', to: 'partners/dashboard#index', as: :partner_dashboard
  get '/p/:code', to: 'leads#track', as: :referral_redirect

  namespace :partners do
    resource :profile, controller: "profile", only: [:edit, :update]

    resources :links, only: [:index, :create, :edit, :update] do
      member do
        get :qr    # /partners/links/:id/qr(.:format)
      end
    end

    resources :payouts, only: [:index, :show] do
      collection do
        get :banking
      end
    end
    resources :leads, only: [:index, :show]
    resources :analytics, only: [:index]
    get 'resources', to: 'dashboard#resources'
    get 'transactions', to: 'dashboard#transactions'
  end

  get "/health", to: "health#show" # endpoint for auto deployments to ping to see if the service is active


  #### END PARTNERS

  # Obfuscated workspace switching (uses Workspace#signed_id)
  get "/workspaces/switch/:token", to: "workspaces#switch", as: :switch_workspace_token

  resources :workspaces do
    get  :manage_billing, on: :member
    match :switch,        on: :member, via: [:get, :post] # legacy numeric id route

    # messages ↴
    resources :messages,
              only: [:index],
              module: :workspaces

    # members ↴
    resources :members,
              controller: 'workspaces/members',
              only: [:index] do
      post :invite,     on: :member
      post :invite_all, on: :collection
    end

    # invite sub‑users ↴
    resources :users, only: [:index, :new, :create] do
      collection { post :invite }
    end
  end

  # Admin namespace for admin-only features  
  namespace :admin do
    resources :users, only: [:index]
    post 'masquerade/:id', to: 'masquerades#create', as: :become_user
    delete 'masquerade', to: 'masquerades#destroy', as: :exit_masquerade
  end
end
