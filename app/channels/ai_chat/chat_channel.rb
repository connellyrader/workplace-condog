# frozen_string_literal: true

class AiChat::ChatChannel < ApplicationCable::Channel
  def subscribed
    stream_from stream_key

    @conversation = conversation_scope.find_by(id: params[:conversation_id])
    reject unless @conversation
  end

  def send_message(payload)
    # Reload from DB so any conversation metadata stays current before calling OpenAI.
    @conversation = conversation_scope.find_by(id: params[:conversation_id])
    return broadcast(type: "error", message: "Conversation not found.") unless @conversation

    content        = (payload["content"] || "").to_s.strip
    options        = (payload["options"] || {}).deep_symbolize_keys
    return broadcast(type: "error", message: "Message cannot be blank.") if content.blank?

    # Persist user message
    @conversation.messages.create!(role: "user", content: content)
    @conversation.touch_activity!

    # Auto-title conversation if needed
    if @conversation.title.blank? || @conversation.title.to_s.strip.casecmp("New conversation").zero?
      new_title = AiChat::Title.from_text(content)
      if new_title.present? && new_title != @conversation.title
        @conversation.update_columns(title: new_title, updated_at: Time.current)
        broadcast(type: "rename", conversation: { id: @conversation.id, title: new_title })
      end
    end

    AiChat::ChatRunner.new(
      conversation: @conversation,
      user: current_user,
      content: content,
      options: options,
      broadcaster: method(:broadcast)
    ).run
  rescue => e
    Rails.logger.error("[AiChat::ChatChannel] #{e.class}: #{e.message}")
    broadcast(type: "error", message: "Chat failed. Please try again.")
  end

  private

  def conversation_scope
    wid = connection.respond_to?(:active_workspace_id) ? connection.active_workspace_id : nil
    scope = current_user.ai_chat_conversations
    wid.present? ? scope.where(workspace_id: wid) : scope
  end

  def stream_key
    cid = params[:conversation_id].to_s
    "ai_chat:conv:#{cid}:user:#{current_user.id}"
  end

  def broadcast(payload)
    ActionCable.server.broadcast(stream_key, payload)
  end
end
