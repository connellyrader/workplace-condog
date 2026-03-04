# app/controllers/admin/prompt_test_runs_controller.rb
class Admin::PromptTestRunsController < ApplicationController
  before_action :authenticate_admin

  DEFAULT_LIMIT = 20

  def index
    runs = PromptTestRun.all
    runs = runs.for_key(params[:prompt_key]) if params[:prompt_key].present?
    runs = runs.where(prompt_type: params[:prompt_type]) if params[:prompt_type].present?
    runs = runs.for_version(params[:prompt_version_id]) if params[:prompt_version_id].present?
    limit = (params[:limit].presence || DEFAULT_LIMIT).to_i
    limit = DEFAULT_LIMIT if limit <= 0
    runs = runs.recent_first.limit(limit)

    render json: { runs: runs.map(&:as_json_for_api) }
  end
end
