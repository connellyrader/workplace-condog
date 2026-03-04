require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing
  config.server_timing = true

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true

    config.cache_store = :memory_store
    config.public_file_server.headers = {
      "Cache-Control" => "public, max-age=#{2.days.to_i}"
    }
  else
    config.action_controller.perform_caching = false

    config.cache_store = :null_store
  end

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local
  config.active_storage.variant_processor = :vips

  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.perform_caching = false
  config.action_mailer.delivery_method = ENV["POSTMARK_SERVER_API_KEY"].present? ? :postmark : :test
  ca_file = ENV["SSL_CERT_FILE"] || "/opt/homebrew/etc/ca-certificates/cert.pem"
  config.action_mailer.postmark_settings = {
    api_token: ENV.fetch("POSTMARK_SERVER_API_KEY", "dummy-key-for-local-dev"),
    ssl_ca_file: ca_file,
    ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE # dev-only: bypass local TLS issues
  }
  config.action_mailer.default_url_options = { host: "www.lrb.sh", protocol: "https" }
  config.action_mailer.default_options = { from: "Workplace.io <noreply@email.workplace.io>" }

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true

  # Raise error when a before_action's only/except options reference missing actions
  config.action_controller.raise_on_missing_callback_actions = true

  # Encryption keys: use ENV if set, else dev-only fallbacks (do not use in production)
  config.active_record.encryption.primary_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY") { "dev-primary-key-#{Rails.application.secret_key_base[0..31]}" }
  config.active_record.encryption.deterministic_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY") { "dev-deterministic-key-#{Rails.application.secret_key_base[32..63]}" }
  config.active_record.encryption.key_derivation_salt = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT") { "dev-salt-#{Rails.application.secret_key_base[64..95]}" }
  # Allow reading unencrypted data (e.g. demo generator uses upsert_all which bypasses encryption)
  config.active_record.encryption.support_unencrypted_data = true

  config.hosts << "5vpulse.ngrok.dev"
  config.hosts << "www.lrb.sh"
  config.hosts << "workplace.ngrok.dev"

  Rails.application.routes.default_url_options[:host] = "www.lrb.sh"

  # Lookbook component catalog
  config.lookbook.preview_layout = "lookbook_preview"
  config.lookbook.preview_paths = ["test/components/previews"]

end
