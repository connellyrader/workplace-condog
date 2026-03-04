class UpdateClaraOverviewPromptVersion < ActiveRecord::Migration[7.0]
  LABEL = "Metric overview (rolling 30-day scores)"

  def up
    return unless table_exists?(:prompt_versions)

    content = Clara::OverviewGenerator.new(
      overview: ClaraOverview.new(workspace: Workspace.new, metric: Metric.new, status: :pending),
      workspace: Workspace.new,
      metric: Metric.new,
      stream_key: "noop",
      range_start: Date.current,
      range_end: Date.current,
      member_ids: nil
    ).send(:default_system_prompt)

    active = PromptVersion.active_for("clara_overview")
    return if active&.content.to_s.strip == content.to_s.strip

    PromptVersion.create!(
      key: "clara_overview",
      label: LABEL,
      content: content,
      active: true
    )
  end

  def down
    return unless table_exists?(:prompt_versions)

    prompt = PromptVersion.where(key: "clara_overview", label: LABEL).order(version: :desc).first
    prompt&.destroy

    PromptVersion.where(key: "clara_overview").order(version: :desc).first&.update!(active: true)
  end
end
