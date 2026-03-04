# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# require_relative 'seeds/categories_and_subcategories'
# require_relative 'seeds/frameworks_and_framework_subcategories'

# require_relative 'seeds/frameworks/4dx'

# Development: demo user + minimal metrics for local dashboard with dummy data
require_relative "seeds/development" if Rails.env.development?
