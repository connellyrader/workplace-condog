# app/controllers/ai_chat/conversations_controller.rb
class AiChat::ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation, only: [:show, :update, :destroy]

  # Full-screen chat shell (default signed-in home).
  def home
    @chat_primary_layout = true
    @version = "v26.040"
  end

  def index
    @conversations = conversation_scope.recent_first
    respond_to do |fmt|
      fmt.html # renders widget page (below)
      fmt.json { render json: @conversations.as_json(only: [:id, :title, :updated_at, :last_activity_at, :workspace_id]) }
    end
  end

  def show
    messages = @conversation.messages.order(:created_at).map do |m|
      meta = m.meta || {}

      # Legacy path: we no longer use blocks/embeds for new messages, but still
      # hydrate any persisted inline_blocks, and synthesize inline blocks for
      # old pipe-style sparkline markers like:
      #   {{block:sparkline_chart|conflict|pos_rate|2025-08-21|2025-11-18}}

      inline_blocks = Array(meta["inline_blocks"]).map { |b| b }.compact
      content = m.content.to_s

      if inline_blocks.blank?
        legacy_blocks = []
        content = content.gsub(/\{\{block:(sparkline_chart\|[^}]+)\}\}/) do |match|
          token = Regexp.last_match(1)
          parts = token.to_s.split("|")
          # expected: ["sparkline_chart","metric_slug","metric_kind","start_date","end_date"]
          if parts.size == 5
            _kind, slug, metric_kind, start_s, end_s = parts
            metric_name = slug.to_s.tr("-", " ").strip
            metric = Metric.where("LOWER(name) = ?", metric_name.downcase).first
            begin
              from = Date.parse(start_s)
              to   = Date.parse(end_s)
            rescue ArgumentError
              metric = nil
            end

            if metric && from && to
              anchor = "blk_#{SecureRandom.hex(4)}"
              params = {
                category: nil,
                start_date: from,
                end_date:   to,
                metric:     metric_kind,
                workspace_id: nil,
                channel_ids:  nil,
                metric_ids:   [metric.id],
                submetric_ids: [],
                subcategory_ids: []
              }

              html, key = AiChat::WidgetRenderer.render(
                kind:   :sparkline,
                user:   current_user,
                params: params,
                points: nil,
                metric: metric_kind,
                title:  metric.name,
                width:  (ENV["AI_CHAT_SPARK_W"] || 800).to_i,
                height: (ENV["AI_CHAT_SPARK_H"] || 260).to_i
              )

              legacy_blocks << {
                "type"   => "widget",
                "kind"   => "sparkline",
                "title"  => metric.name,
                "key"    => key,
                "params" => params,
                "html"   => html,
                "anchor" => anchor
              }

              "{{block:#{anchor}}}"
            else
              match
            end
          else
            match
          end
        end

        inline_blocks.concat(legacy_blocks) if legacy_blocks.any?
      end

      { id: m.id, role: m.role, content: content, inline_blocks: inline_blocks }
    end

    render json: {
      id: @conversation.id,
      workspace_id: @conversation.workspace_id,
      title: @conversation.title,
      system_prompt: AiChat::Prompts.system,
      prompt_locked: messages.any?,
      messages: messages
    }
  end

  def create
    # Accept an explicit title if you ever pass one; otherwise leave nil so first message can set it.
    title = params[:title].to_s.strip
    title = "New conversation" if title.blank?
    workspace = @active_workspace || current_user.workspaces.where(archived_at: nil).order(:created_at).first
    return render json: { error: "Active workspace required." }, status: :unprocessable_entity unless workspace

    conv = current_user.ai_chat_conversations.create!(
      workspace: workspace,
      title: title
    )
    render json: { id: conv.id, title: conv.title, workspace_id: conv.workspace_id, system_prompt: AiChat::Prompts.system }, status: :created
  end

  def update
    render json: { error: "System prompt is managed globally and cannot be edited." }, status: :unprocessable_entity
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
    current_user.ai_chat_conversations.for_workspace(@active_workspace)
  end

end
