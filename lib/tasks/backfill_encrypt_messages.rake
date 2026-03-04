namespace :backfill do
  desc "Encrypt all existing Message#text into the new encrypted column"
  task encrypt_messages: :environment do
    Message.find_each do |m|
      # assuming you’ve set up `has_encrypted :text` or similar in your model...
      m.text = m.text   # trigger the ActiveRecord setter to encrypt
      m.save!(validate: false)
      puts "Encrypted Message #{m.id}"
    end
    puts "✅ All done!"
  end
end
