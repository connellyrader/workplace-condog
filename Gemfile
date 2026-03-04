source "https://rubygems.org"

ruby "3.3.0"

# -------------------------------------------------------------------
# Core Rails
# -------------------------------------------------------------------
gem "rails", "~> 7.1.5", ">= 7.1.5.1"

# Asset pipeline + CSS
gem "sprockets-rails"
gem "sassc-rails"
gem "bootstrap", "~> 5.2.3"
gem "jquery-rails" # Bootstrap JS dependency / legacy jQuery usage

# -------------------------------------------------------------------
# Database & persistence
# -------------------------------------------------------------------
gem "pg", "~> 1.1"
gem "pgvector", "~> 0.3.2" # vector embeddings / similarity search

# -------------------------------------------------------------------
# Web server
# -------------------------------------------------------------------
gem "puma", ">= 5.0"

# -------------------------------------------------------------------
# Front-end (Hotwire)
# -------------------------------------------------------------------
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"

# -------------------------------------------------------------------
# API / JSON
# -------------------------------------------------------------------
gem "jbuilder"

# -------------------------------------------------------------------
# Caching / real-time
# -------------------------------------------------------------------
gem "redis", ">= 4.0.1" # ActionCable adapter in production
# gem "kredis"          # higher-level Redis types (optional)

# -------------------------------------------------------------------
# Authentication / configuration
# -------------------------------------------------------------------
gem "devise"
gem "devise_masquerade"
gem "figaro"

gem "rack-attack"

# OmniAuth + SSO providers (login-only SSO)
gem "omniauth"
gem "omniauth_openid_connect"        # Slack OIDC sign-in flow
gem "omniauth-google-oauth2"         # Google SSO
gem "omniauth-entra-id"              # Microsoft Entra ID (work/school accounts) SSO
gem "omniauth-rails_csrf_protection" # recommended with OmniAuth 2

# -------------------------------------------------------------------
# Payments
# -------------------------------------------------------------------
gem "stripe"

# -------------------------------------------------------------------
# Background jobs
# -------------------------------------------------------------------
gem "sidekiq"

# -------------------------------------------------------------------
# Integrations & external services
# -------------------------------------------------------------------
gem "slack-ruby-client"

# OpenAI / LLM
gem "ruby-openai", ">= 6.0"

# Language detection (Google's CLD3 - offline, free, highly accurate)
gem "cld3"

# HTTP utilities
gem "httparty"

# -------------------------------------------------------------------
# AWS SDKs
# -------------------------------------------------------------------
gem "aws-sdk-sagemaker"
gem "aws-sdk-sagemakerruntime"
gem "aws-sdk-applicationautoscaling"
gem "aws-sdk-cloudwatch"
gem "aws-sdk-s3"
gem "aws-sdk-sns"
gem "aws-sdk-ecr"

# -------------------------------------------------------------------
# Scheduling / cron
# -------------------------------------------------------------------
gem "whenever"

# -------------------------------------------------------------------
# Analytics / reporting helpers
# -------------------------------------------------------------------
gem "groupdate"

# -------------------------------------------------------------------
# Email
# -------------------------------------------------------------------
gem "postmark-rails"

# -------------------------------------------------------------------
# Device + geo / enrichment
# -------------------------------------------------------------------
gem "device_detector"
gem "maxminddb"
gem "public_suffix", "~> 6.0"

# -------------------------------------------------------------------
# QR codes
# -------------------------------------------------------------------
gem "rqrcode", "~> 2.2"
gem "chunky_png", "~> 1.4" # needed for PNG output

# -------------------------------------------------------------------
# Image processing
# -------------------------------------------------------------------
gem "mini_magick", "~> 4.12"
gem "image_processing", "~> 1.12"
gem "ruby-vips" # used by image_processing via libvips

# -------------------------------------------------------------------
# Pagination
# -------------------------------------------------------------------
gem "kaminari"

# -------------------------------------------------------------------
# NLP / tokenization
# -------------------------------------------------------------------
gem "tiktoken_ruby", "~> 0.0.11.1"
gem "sentimental", "~> 1.0"

# -------------------------------------------------------------------
# Performance / boot
# -------------------------------------------------------------------
gem "bootsnap", require: false

# -------------------------------------------------------------------
# Debugging
# -------------------------------------------------------------------
gem "byebug"

# -------------------------------------------------------------------
# Platform-specific
# -------------------------------------------------------------------
gem "tzinfo-data", platforms: %i[mingw mswin x64_mingw jruby]

# -------------------------------------------------------------------
# Dev / Test groups
# -------------------------------------------------------------------
group :development, :test do
  gem "debug", platforms: %i[mri mingw mswin x64_mingw]
end

group :development do
  gem "web-console"
  gem "lookbook", ">= 2.3"
  # gem "rack-mini-profiler"
  # gem "spring"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
end
