# lib/tasks/demo_workspace.rake
namespace :demo do
  desc "Generate nightly demo messages + detections for the Demo Workspace"
  task generate_daily: :environment do
    date_str = ENV["DATE"] # optional YYYY-MM-DD
    date = date_str.present? ? Date.parse(date_str) : Time.zone.today

    Rails.logger.info "[demo:generate_daily] date=#{date}"
    DemoData::Generator.new(date: date).run!

    # Keep demo AI chat fresh: clear conversations/messages nightly.
    demo_ws = Workspace.find_by(name: DemoData::Generator::DEMO_WORKSPACE_NAME)
    if demo_ws
      Rails.logger.info "[demo:generate_daily] clearing_ai_chat workspace_id=#{demo_ws.id}"
      conv_ids = AiChat::Conversation.where(workspace_id: demo_ws.id).pluck(:id)
      if conv_ids.any?
        AiChat::Message.where(ai_chat_conversation_id: conv_ids).delete_all
        AiChat::Conversation.where(id: conv_ids).delete_all
      end
    end

    Rails.logger.info "[demo:generate_daily] done date=#{date}"
  end
end
