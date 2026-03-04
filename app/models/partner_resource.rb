class PartnerResource < ApplicationRecord
  has_one_attached :file

  RESOURCE_TYPES = {
    "file"  => "File",
    "color" => "Color"
  }.freeze

  CATEGORIES = {
    "logos"       => "Logos",
    "brand_colors" => "Brand Colors",
    "whitepapers" => "Whitepapers",
    "books"       => "Books",
    "keynotes"    => "Keynotes",
    "videos"      => "Videos",
    "other"       => "Other"
  }.freeze

  validates :title, presence: true
  validates :category, presence: true, inclusion: { in: CATEGORIES.keys }
  validates :resource_type, presence: true, inclusion: { in: RESOURCE_TYPES.keys }

  validate :file_or_url_present, if: :file_type?
  validates :hex, presence: true, if: :color_type?
  validate :hex_format, if: :color_type?

  scope :ordered, -> { order(Arel.sql("category ASC, position ASC, created_at ASC")) }

  def category_label
    CATEGORIES[category.to_s] || category.to_s.humanize
  end

  def download_url
    return nil unless file.attached? || url.present?
    return url if url.present?
    file
  end

  def file_type?
    resource_type.to_s == "file"
  end

  def color_type?
    resource_type.to_s == "color"
  end

  private

  def file_or_url_present
    if !file.attached? && url.to_s.strip.blank?
      errors.add(:base, "Attach a file or provide a URL")
    end
  end

  def hex_format
    v = hex.to_s.strip
    return if v.match?(/^#(?:[0-9a-fA-F]{3}){1,2}$/)
    errors.add(:hex, "must look like #RRGGBB")
  end
end
