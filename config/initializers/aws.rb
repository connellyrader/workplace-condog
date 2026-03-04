### INTERFERES WITH DigitalOcean SPACES CONFIG IN STORAGE YML

# Aws.config.update({
#   region: 'us-east-2',
#   credentials: Aws::Credentials.new(
#     ENV['AWS_ACCESS_KEY_ID'],
#     ENV['AWS_SECRET_ACCESS_KEY']
#   )
# })

if Rails.env.development? || Rails.env.test?
  require "aws-sdk-core"
  Aws.use_bundled_cert!           # <- one line fix for local TLS
end
