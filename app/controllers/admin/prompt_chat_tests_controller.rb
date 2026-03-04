# app/controllers/admin/prompt_chat_tests_controller.rb
class Admin::PromptChatTestsController < ApplicationController
  before_action :authenticate_admin
  before_action :set_conversation, only: [:show, :destroy]

  def index
    conversations = conversation_scope.recent_first
    render json: conversations.as_json(only: [:id, :title, :updated_at, :last_activity_at, :workspace_id])
  end

  def show
    messages = @conversation.messages.order(:created_at).map do |m|
      { id: m.id, role: m.role, content: m.content, inline_blocks: [] }
    end

    render json: {
      id: @conversation.id,
      workspace_id: @conversation.workspace_id,
      title: @conversation.title,
      system_prompt: @conversation.system_prompt,
      prompt_locked: messages.any?,
      messages: messages
    }
  end

  def create
    workspace = current_workspace
    return render json: { error: "Workspace required." }, status: :unprocessable_entity unless workspace

    conv = current_user.ai_chat_conversations.create!(
      workspace: workspace,
      title: params[:title].presence || "Prompt test chat",
      system_prompt: prompt_content_from_params,
      purpose: "prompt_test"
    )

    render json: {
      id: conv.id,
      title: conv.title,
      workspace_id: conv.workspace_id,
      last_activity_at: conv.last_activity_at,
      updated_at: conv.updated_at
    }, status: :created
  end

  def destroy
    @conversation.destroy
    head :no_content
  end

  private

  def set_conversation
    @conversation = conversation_scope.find(params[:id])
  end

  def conversation_scope
    current_user.ai_chat_conversations.where(purpose: "prompt_test")
  end

  def prompt_content_from_params
    PromptVersion.find_by(id: params[:prompt_version_id])&.content.presence || AiChat::Prompts.system
  end

  def current_workspace
    @active_workspace || current_user.workspaces.where(archived_at: nil).order(:created_at).first
  end
end
