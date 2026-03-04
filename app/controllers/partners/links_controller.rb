# app/controllers/partners/links_controller.rb
module Partners
  class LinksController < Partners::BaseController
    def index
      if current_user.links.none?
        current_user.links.create!(code: generate_unique_code)
      end
      @links = current_user.links.includes(:link_clicks)
    end

    def create
      @link = current_user.links.create!(code: generate_unique_code)
      redirect_to partners_links_path, notice: "Link created successfully."
    end

    def edit
      @link = current_user.links.find(params[:id])
    end

    def update
      @link = current_user.links.find(params[:id])
      if @link.update(link_params)
        redirect_to partners_links_path, notice: "Link updated."
      else
        flash.now[:alert] = @link.errors.full_messages.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end

    def qr
      link = current_user.links.find(params[:id])
      url  = referral_redirect_url(code: link.code)

      size = params[:size].to_i
      size = 512 if size <= 0 || size > 2048

      # 1) Build QR (high EC so a center logo is fine)
      qr = RQRCode::QRCode.new(url, level: :h)
      qr_png = qr.as_png(
        size:           size,
        border_modules: 4,
        color:          "black",
        fill:           "white"
      )

      # 2) Resolve logo.png
      logo_path = begin
        candidates = [
          Rails.root.join("app/assets/images/logo.png"),
          Rails.root.join("public/logo.png")
        ]
        if (m = Rails.application.assets_manifest rescue nil)&.assets.is_a?(Hash)
          if (digest_rel = m.assets["logo.png"])
            candidates << Rails.root.join("public", "assets", digest_rel)
          end
        end
        candidates.find { |p| File.exist?(p) }
      end

      unless logo_path
        Rails.logger.warn("[QR] logo.png not found; sending plain QR")
        return send_data qr_png.to_s,
          type: "image/png",
          disposition: "attachment",
          filename: "qr-#{link.code}.png"
      end

      begin
        MiniMagick.configure { |c| c.cli = :imagemagick }

        qr_img   = MiniMagick::Image.read(qr_png.to_s)
        logo_img = MiniMagick::Image.open(logo_path.to_s)

        qr_img.colorspace   "sRGB" rescue nil
        logo_img.colorspace "sRGB" rescue nil

        # ~22% of QR width is a safe logo size; add ~10% white pad behind it
        logo_target = (size * 0.22).to_i
        pad         = (logo_target * 0.10).to_i
        logo_img.resize "#{logo_target}x#{logo_target}"

        canvas_w = logo_target + 2 * pad

        # Create white pad as a blob via `convert`, then read it
        pad_blob = MiniMagick::Tool::Convert.new do |m|
          m.size "#{canvas_w}x#{canvas_w}"
          m.xc "white"          # solid white canvas
          m << "png:-"          # write to stdout as PNG
        end
        pad_canvas = MiniMagick::Image.read(pad_blob)

        # (Optional) faint border for debugging — comment out after verifying
        # pad_canvas.combine_options do |co|
        #   co.stroke "#e5e7eb"
        #   co.strokewidth 1
        #   co.fill "white"
        #   co.draw "rectangle 0,0 #{canvas_w-1},#{canvas_w-1}"
        # end

        padded_logo = pad_canvas.composite(logo_img) { |c| c.compose "Over"; c.gravity "center" }
        final       = qr_img.composite(padded_logo)  { |c| c.compose "Over"; c.gravity "center" }

        send_data final.to_blob,
          type: "image/png",
          disposition: "attachment",
          filename: "#{link.code}.png"

      rescue => e
        Rails.logger.warn("[QR] composite failed: #{e.class} #{e.message}")
        send_data qr_png.to_s,
          type: "image/png",
          disposition: "attachment",
          filename: "#{link.code}.png"
      end
    end


    private

    def link_params
      params.require(:link).permit(:code)
    end

    def generate_unique_code
      base = current_user.full_name.parameterize.presence || SecureRandom.hex(6)
      loop do
        code = base
        code += "-#{SecureRandom.hex(3)}" if Link.exists?(code: code)
        break code unless Link.exists?(code: code)
      end
    end

  end
end
