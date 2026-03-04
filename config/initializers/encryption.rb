# config/initializers/encryption.rb
Rails.application.config.active_record.encryption.tap do |enc|
  base = Rails.application.secret_key_base.to_s
  dev_fallback = Rails.env.development?
  enc.primary_key         = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]         || (dev_fallback ? "dev-primary-#{base[0, 32]}" : nil)
  enc.deterministic_key   = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]   || (dev_fallback ? "dev-deterministic-#{base[32, 32]}" : nil)
  enc.key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]  || (dev_fallback ? "dev-salt-#{base[0, 32]}" : nil)
  if enc.primary_key.blank? || enc.deterministic_key.blank? || enc.key_derivation_salt.blank?
    raise "Set ACTIVE_RECORD_ENCRYPTION_* env vars (or use development mode with fallbacks)"
  end
end
