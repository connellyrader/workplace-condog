# config/initializers/session_store.rb
Rails.application.config.session_store :cookie_store,
  key: '_workplace_session',
  expire_after: 12.months,                  # keep sessions alive up to 1 year
  secure: Rails.env.production?,            # only send over HTTPS in prod
  same_site: :lax                           # prevents CSRF but still works for top-level SSO
  # domain: :all                            # uncomment or use ".yourdomain.com" if you need subdomains
