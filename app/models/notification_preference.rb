class NotificationPreference < ApplicationRecord
  CHANNEL_KEYS = %w[email slack teams].freeze
  TYPE_KEYS    = %w[personal_insights all_group_insights my_group_insights executive_summaries].freeze

  belongs_to :workspace
  belongs_to :user

  def channel_enabled?(key, default: false)
    column = "#{key}_enabled"
    return default unless respond_to?(column)

    value = public_send(column)
    value.nil? ? default : value
  end

  def type_enabled?(key, allowed_types:, default: false)
    return false unless allowed_types.include?(key)

    column = "#{key}_enabled"
    return default unless respond_to?(column)

    value = public_send(column)
    value.nil? ? default : value
  end

  def update_flag!(key, value)
    column = "#{key}_enabled"
    raise ArgumentError, "Unknown notification flag #{key}" unless respond_to?(column)

    bool_value = ActiveModel::Type::Boolean.new.cast(value)
    update!(column => bool_value)
  end
end
