# app/helpers/icon_helper.rb
module IconHelper
  def icon(name, size: 20, class_name: "icon", title: nil)
    path = Rails.root.join("app/assets/images/icons/#{name}.svg")
    return "" unless File.exist?(path)

    svg = File.read(path)

    # Inject width/height + classes
    svg.sub!("<svg", %Q{<svg width="#{size}" height="#{size}" class="#{ERB::Util.html_escape(class_name)}"})

    # Accessibility
    if title
      svg.sub!("<svg", %Q{<svg role="img" aria-label="#{ERB::Util.html_escape(title)}"})
    else
      svg.sub!("<svg", %Q{<svg aria-hidden="true"})
    end

    svg.html_safe
  end
end
