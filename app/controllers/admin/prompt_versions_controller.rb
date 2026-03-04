# app/controllers/admin/prompt_versions_controller.rb
class Admin::PromptVersionsController < ApplicationController
  before_action :authenticate_admin

  def create
    attrs = prompt_version_params
    activating = params.key?(:activate) ? ActiveModel::Type::Boolean.new.cast(params[:activate]) : ActiveModel::Type::Boolean.new.cast(attrs[:active])
    attrs[:active] = activating

    prompt = nil
    PromptVersion.transaction do
      PromptVersion.deactivate_other_actives!(attrs[:key], except_id: nil) if activating
      prompt = PromptVersion.new(attrs)
      prompt.created_by = current_user
      prompt.save!
    end

    redirect_to admin_prompt_path(prompt.key, anchor: anchor_for(prompt)), notice: "Saved prompt version v#{prompt.version}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to admin_prompts_path, alert: e.record.errors.full_messages.to_sentence
  end

  def update
    prompt = PromptVersion.find(params[:id])

    attrs = prompt_version_params
    if params.key?(:active)
      attrs[:active] = ActiveModel::Type::Boolean.new.cast(params[:active])
    end
    activating = ActiveModel::Type::Boolean.new.cast(attrs[:active])

    PromptVersion.transaction do
      PromptVersion.deactivate_other_actives!(prompt.key, except_id: prompt.id) if activating
      prompt.update!(attrs)
    end

    redirect_to admin_prompt_path(prompt.key, anchor: anchor_for(prompt)), notice: "Updated prompt version."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to admin_prompt_path(prompt.key), alert: e.record.errors.full_messages.to_sentence
  end

  private

  def prompt_version_params
    source = params[:prompt_version] || params
    source.permit(:key, :label, :content, :active)
  end

  def anchor_for(prompt)
    prompt.key.to_s.tr(":", "-")
  end
end
