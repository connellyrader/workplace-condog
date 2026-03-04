class Admin::UsersController < ApplicationController
  layout "admin"

  before_action :authenticate_admin

  def index
    @query = params[:q].to_s.strip
    @sort  = params[:sort].presence || "created_at"
    @dir   = params[:dir].presence_in(%w[asc desc]) || "desc"

    allowed_sorts = {
      "created_at" => "users.created_at",
      "email"      => "users.email",
      "first_name" => "users.first_name",
      "last_name"  => "users.last_name",
      "sign_in"    => "users.last_sign_in_at"
    }

    sort_sql = allowed_sorts[@sort] || allowed_sorts["created_at"]

    scope = User.all

    if @query.present?
      like = "%#{@query.downcase}%"
      scope = scope.where("LOWER(users.email) LIKE ? OR LOWER(users.first_name) LIKE ? OR LOWER(users.last_name) LIKE ?", like, like, like)
    end

    @users = scope.order(Arel.sql("#{sort_sql} #{@dir}"))
                  .page(params[:page])
                  .per(50)
  end
end
