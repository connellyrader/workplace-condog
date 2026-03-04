# app/services/messages/pii_scrubber.rb
# frozen_string_literal: true

module Messages
  # Replaces common PII patterns in freeform text with contextual placeholders so we never persist raw values.
  # Filters are applied in order, allowing more specific matchers (keys/tokens) to run before broader ones.
  class PiiScrubber
    Filter = Struct.new(:label, :patterns, :validator, :placeholder, keyword_init: true)

    EMAIL_PATTERN              = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
    CREDIT_CARD_PATTERN        = /(?<!\d)(?:\d[ -]?){13,19}(?!\d)/
    SSN_PATTERN                = /\b\d{3}-\d{2}-\d{4}\b/
    EIN_PATTERN                = /\b\d{2}-\d{7}\b/
    PHONE_PATTERN              = /(?<!\d)(?:\+?\d{1,3}[\s.-]?)?(?:\(?\d{3}\)?[\s.-]?)?\d{3}[\s.-]?\d{4}(?:\s*(?:x|ext\.?)\s*\d{2,6})?(?!\d)/i
    IPV4_PATTERN               = /\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b/
    IPV6_PATTERN               = /\b(?:[A-F0-9]{1,4}:){7}[A-F0-9]{1,4}\b/i
    MAC_PATTERN                = /\b(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b/i
    UUID_PATTERN               = /\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/i
    GUID_PATTERN               = /\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b/
    JWT_PATTERN                = /\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]{10,}\b/
    PEM_PATTERN                = /-----BEGIN (?:RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----.*?-----END (?:RSA |DSA |EC |OPENSSH )?PRIVATE KEY-----/mi
    SLACK_TOKEN_PATTERN        = /\bxox(?:p|b|r|s|o|a)-[A-Za-z0-9-]{10,}\b/
    GITHUB_TOKEN_PATTERN       = /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,255}\b/
    GITHUB_PAT_PATTERN         = /\bgithub_pat_[A-Za-z0-9_]{20,255}\b/
    GITLAB_TOKEN_PATTERN       = /\bglpat-[A-Za-z0-9_-]{20,255}\b/
    STRIPE_KEY_PATTERN         = /\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}\b/
    TWILIO_KEY_PATTERN         = /\bSK[0-9a-f]{32}\b/i
    SENDGRID_KEY_PATTERN       = /\bSG\.[A-Za-z0-9._-]{50,}\b/
    AWS_ACCESS_KEY_PATTERN     = /\b(?:AKIA|ASIA)[A-Z0-9]{12,}\b/
    GCP_OAUTH_PATTERN          = /\bya29\.[0-9A-Za-z._-]{20,}\b/

    # Ruby does NOT allow variable-length lookbehind; use capture groups instead.
    # Captures: (prefix)(token)
    BEARER_TOKEN_CAPTURE       = /(\bBearer\s+)([A-Za-z0-9\-\._~\+\/]+=*)/i

    # Captures: (?token=)(value) or (&api_key=)(value)
    URL_SECRET_CAPTURE         = /([?&](?:token|key|secret|password|pass|auth|session|sig|signature|api[_-]?key)=)([^&\s]+)/i

    # Captures userinfo before @ in a URL:  scheme://user:pass@host
    # Captures: (scheme://)(userinfo)
    URL_USERINFO_CAPTURE       = %r{(://)([A-Za-z0-9._%+-]{1,50}:[^@\s]{4,}?)(@)}i

    GENERIC_TOKEN_PATTERN      = /\b[A-Za-z0-9_\-]{24,}\b/
    IBAN_PATTERN               = /\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b/
    ROUTING_NUMBER_PATTERN     = /\b\d{9}\b/
    DOB_YMD_PATTERN            = /\b(?:19|20)\d{2}[-\/](?:0?[1-9]|1[0-2])[-\/](?:0?[1-9]|[12]\d|3[01])\b/
    DOB_MDY_PATTERN            = /\b(?:0?[1-9]|1[0-2])[-\/](?:0?[1-9]|[12]\d|3[01])[-\/](?:19|20)\d{2}\b/
    DOB_TEXT_PATTERN           = /\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+(?:19|20)\d{2}\b/i
    GPS_COORD_PATTERN          = /[-+]?\d{1,2}\.\d+,\s*[-+]?\d{1,3}\.\d+/

    # Captures: (label-ish)(digits)
    OTP_CAPTURE                = /(\b(?:code|otp|2fa|verification|passcode)\b\D{0,5})(\d{6,8}\b)/i

    ICD10_PATTERN              = /\b[A-TV-Z]\d{2}\.\d{1,4}\b/i

    # Captures: (mrn[:\s]*)(id)
    MRN_CAPTURE                = /(\bmrn[:\s]*)([A-Za-z0-9]{6,12}\b)/i

    ADDRESS_PATTERN            = /\b\d{1,5}\s+[A-Za-z0-9][A-Za-z0-9\s'.-]{1,30}\s+(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Lane|Ln|Dr|Drive|Court|Ct|Pl|Place|Pkwy|Parkway)\b[^\n]{0,30}\b\d{5}(?:-\d{4})?\b/i

    DEFAULT_FILTERS = [
      # Secrets / tokens
      Filter.new(label: "TOKEN_PEM", patterns: [PEM_PATTERN]),
      Filter.new(label: "TOKEN_JWT", patterns: [JWT_PATTERN]),
      Filter.new(label: "TOKEN_SLACK", patterns: [SLACK_TOKEN_PATTERN]),
      Filter.new(label: "TOKEN_GITHUB", patterns: [GITHUB_TOKEN_PATTERN, GITHUB_PAT_PATTERN]),
      Filter.new(label: "TOKEN_GITLAB", patterns: [GITLAB_TOKEN_PATTERN]),
      Filter.new(label: "TOKEN_STRIPE", patterns: [STRIPE_KEY_PATTERN]),
      Filter.new(label: "TOKEN_TWILIO", patterns: [TWILIO_KEY_PATTERN]),
      Filter.new(label: "TOKEN_SENDGRID", patterns: [SENDGRID_KEY_PATTERN]),
      Filter.new(label: "TOKEN_AWS", patterns: [AWS_ACCESS_KEY_PATTERN]),
      Filter.new(label: "TOKEN_GCP", patterns: [GCP_OAUTH_PATTERN]),

      # Bearer tokens: preserve "Bearer " prefix, redact token
      Filter.new(
        label: "TOKEN_BEARER",
        patterns: [BEARER_TOKEN_CAPTURE],
        placeholder: ->(_count) { "#{Regexp.last_match(1)}[TOKEN_BEARER]" }
      ),

      # Query-string secrets: preserve "token=" prefix, redact value
      Filter.new(
        label: "TOKEN_URL_SECRET",
        patterns: [URL_SECRET_CAPTURE],
        placeholder: ->(_count) { "#{Regexp.last_match(1)}[TOKEN_URL_SECRET]" }
      ),

      # URL userinfo (scheme://user:pass@): preserve separators, redact userinfo only
      Filter.new(
        label: "TOKEN_URL_AUTH",
        patterns: [URL_USERINFO_CAPTURE],
        placeholder: ->(_count) { "#{Regexp.last_match(1)}[TOKEN_URL_AUTH]#{Regexp.last_match(3)}" }
      ),

      Filter.new(
        label: "TOKEN_GENERIC",
        patterns: [GENERIC_TOKEN_PATTERN],
        validator: ->(match, _) { PiiScrubber.high_entropy_token?(match) }
      ),

      # Financial / government
      Filter.new(label: "CREDIT_CARD", patterns: [CREDIT_CARD_PATTERN], validator: ->(match, _) { PiiScrubber.luhn_valid?(match) }),
      Filter.new(label: "IBAN", patterns: [IBAN_PATTERN], validator: ->(match, _) { PiiScrubber.iban_valid?(match) }),
      Filter.new(label: "ROUTING_NUMBER", patterns: [ROUTING_NUMBER_PATTERN], validator: ->(match, _) { PiiScrubber.aba_valid?(match) }),
      Filter.new(label: "SSN", patterns: [SSN_PATTERN]),
      Filter.new(label: "EIN", patterns: [EIN_PATTERN]),

      # Identity / contact / location
      Filter.new(label: "EMAIL", patterns: [EMAIL_PATTERN]),
      Filter.new(
        label: "PHONE",
        patterns: [PHONE_PATTERN],
        validator: ->(match, _) { digits = match.gsub(/\D/, ""); digits.length.between?(7, 16) }
      ),
      Filter.new(label: "ADDRESS", patterns: [ADDRESS_PATTERN]),
      Filter.new(label: "DOB", patterns: [DOB_YMD_PATTERN, DOB_MDY_PATTERN, DOB_TEXT_PATTERN]),
      Filter.new(label: "GPS_COORD", patterns: [GPS_COORD_PATTERN]),

      # Health context (lightweight)
      Filter.new(
        label: "HEALTH_ICD",
        patterns: [ICD10_PATTERN],
        validator: ->(_, md) { PiiScrubber.keyword_nearby?(md, %w[icd diagnosis diagnosed positive]) }
      ),
      Filter.new(
        label: "HEALTH_MRN",
        patterns: [MRN_CAPTURE],
        validator: ->(_, md) { PiiScrubber.keyword_nearby?(md, %w[mrn patient chart]) },
        placeholder: ->(_count) { "#{Regexp.last_match(1)}[HEALTH_MRN]" }
      ),

      # One-time codes / auth flows
      Filter.new(
        label: "OTP",
        patterns: [OTP_CAPTURE],
        validator: ->(match, md) { match.length.between?(6, 8) && PiiScrubber.keyword_nearby?(md, %w[code otp 2fa verification passcode]) },
        placeholder: ->(_count) { "#{Regexp.last_match(1)}[OTP]" }
      ),

      # Network / device identifiers
      Filter.new(label: "IPV4", patterns: [IPV4_PATTERN]),
      Filter.new(label: "IPV6", patterns: [IPV6_PATTERN]),
      Filter.new(label: "MAC", patterns: [MAC_PATTERN]),
      Filter.new(label: "UUID", patterns: [UUID_PATTERN, GUID_PATTERN])
    ].freeze

    def self.scrub(text, filters: DEFAULT_FILTERS)
      new(filters: filters).scrub(text)
    end

    def initialize(filters: DEFAULT_FILTERS)
      @filters = filters
    end

    def scrub(text)
      return "" if text.nil?

      counters = Hash.new(0)
      @filters.reduce(text.to_s.dup) do |memo, filter|
        apply_filter(memo, filter, counters)
      end
    end

    private

    def apply_filter(text, filter, counters)
      Array(filter.patterns).reduce(text) do |memo, pattern|
        memo.gsub(pattern) do |match|
          match_data = Regexp.last_match
          next match if filter.validator && !filter.validator.call(match, match_data)

          counters[filter.label] += 1
          build_placeholder(filter, counters[filter.label])
        end
      end
    end

    def build_placeholder(filter, count)
      return filter.placeholder.call(count) if filter.placeholder
      count > 1 ? "[#{filter.label}_#{count}]" : "[#{filter.label}]"
    end

    def self.luhn_valid?(value)
      digits = value.gsub(/\D/, "")
      return false unless digits.length.between?(13, 19)

      sum = digits.chars.reverse.each_with_index.sum do |char, idx|
        num = char.to_i
        if idx.odd?
          num *= 2
          num -= 9 if num > 9
        end
        num
      end

      sum % 10 == 0
    end

    def self.aba_valid?(value)
      digits = value.gsub(/\D/, "")
      return false unless digits.length == 9

      weights = [3, 7, 1, 3, 7, 1, 3, 7, 1]
      total = digits.chars.map(&:to_i).zip(weights).sum { |d, w| d * w }
      total % 10 == 0
    end

    def self.iban_valid?(value)
      stripped = value.delete(" ")
      return false unless stripped.length.between?(15, 34)

      rearranged = stripped[4..] + stripped[0, 4]
      numeric = rearranged.chars.map { |ch| ch =~ /[A-Z]/ ? (ch.ord - 55).to_s : ch }.join
      numeric.to_i % 97 == 1
    rescue
      false
    end

    def self.high_entropy_token?(value)
      token = value.to_s.strip
      return false if token.length < 24
      entropy(token) >= 3.5
    end

    def self.entropy(str)
      counts = str.chars.tally
      len = str.length.to_f
      counts.values.reduce(0.0) do |memo, count|
        p = count / len
        memo - (p * Math.log2(p))
      end
    end

    def self.keyword_nearby?(match_data, keywords, window: 32)
      return false unless match_data

      before = match_data.pre_match.to_s[-window..] || ""
      after  = match_data.post_match.to_s[0...window] || ""
      snippet = "#{before} #{after}".downcase
      Array(keywords).any? { |k| snippet.include?(k.to_s.downcase) }
    end
  end
end
