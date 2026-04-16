# lib/tasks/demo_populate.rake
namespace :demo do
  desc "Populate the Demo Workspace with fake account-holder users for admin/settings pages"
  task populate_account_holders: :environment do
    load Rails.root.join("db/seeds/demo_account_holders.rb")
  end

  desc "Create/refresh the 'Get started with Clara' scripted onboarding conversation"
  task populate_onboarding_conversation: :environment do
    load Rails.root.join("db/seeds/onboarding_conversation.rb")
  end
end
