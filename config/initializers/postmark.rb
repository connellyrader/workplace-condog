# frozen_string_literal: true

# Dev-only Postmark SSL override to allow local testing even when the
# host OpenSSL trust chain/CRL lookup fails. Production is unaffected.
if Rails.env.development?
  module Postmark
    class HttpClient
      alias_method :build_http_without_dev_ssl_override, :build_http

      private

      def build_http
        build_http_without_dev_ssl_override.tap do |http|
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE

          next unless ENV["SSL_CERT_FILE"].present?

          store = OpenSSL::X509::Store.new
          store.set_default_paths
          store.add_file(ENV["SSL_CERT_FILE"])
          http.cert_store = store
        end
      end
    end
  end
end
