namespace :dashboard do
  desc "Warm dashboard caches for active workspaces/groups"
  task warm_cache: :environment do
    max_workspaces = ENV.fetch("WARM_TOP_WORKSPACES", "20").to_i
    max_groups = ENV.fetch("WARM_TOP_GROUPS", "3").to_i

    workspaces = Workspace.where(archived_at: nil).order(updated_at: :desc).limit(max_workspaces)
    warmer = DashboardCacheWarmer.new

    count = 0
    workspaces.each do |workspace|
      warmer.warm!(workspace: workspace, group: nil)
      count += 1

      groups = workspace.groups
        .left_joins(:group_members)
        .group("groups.id")
        .having("COUNT(DISTINCT group_members.integration_user_id) >= 3")
        .order(updated_at: :desc)
        .limit(max_groups)

      groups.each do |group|
        warmer.warm!(workspace: workspace, group: group)
      end
    end

    Rails.logger.info("[DashboardCacheWarm] warmed workspaces=#{count} max_groups=#{max_groups}")
  end
end
