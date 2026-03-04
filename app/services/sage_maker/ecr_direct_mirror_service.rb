# frozen_string_literal: true
#
# Mirrors a source ECR image into YOUR account/region without Docker/CodeBuild.
# - Handles Docker v2 / OCI manifests AND multi-arch manifest lists
# - Streams missing blobs (layers + config) into your destination ECR repo
# - Writes the concrete child manifest under DEST_TAG in your repo
#
# Usage (example):
#   dest_uri = EcrDirectMirrorService.new.ensure_mirrored!(
#     "763104351884.dkr.ecr.us-east-1.amazonaws.com/huggingface-pytorch-inference:2.6.0-transformers4.49.0-cpu-py312-ubuntu22.04"
#   )
#   # => "388410206920.dkr.ecr.us-east-2.amazonaws.com/huggingface-pytorch-inference:2.6.0-transformers4.49.0-cpu-py312-ubuntu22.04"
#


# ecr_direct_mirror_service.rb
# Mirrors container images between registries (e.g., an upstream image into AWS ECR) so deployments can pull
# from your controlled registry without relying on the original source at runtime.

require "aws-sdk-ecr"
require "json"
require "net/http"
require "uri"
require "open-uri"

module SageMaker
  class EcrDirectMirrorService
    URI_RE          = %r{\A(?<acct>\d+)\.dkr\.ecr\.(?<region>[a-z0-9-]+)\.amazonaws\.com/(?<repo>[^:]+):(?<tag>[^\s:]+)\z}i
    MT_DOCKER       = "application/vnd.docker.distribution.manifest.v2+json"
    MT_OCI          = "application/vnd.oci.image.manifest.v1+json"
    MT_DOCKER_LIST  = "application/vnd.docker.distribution.manifest.list.v2+json"
    MT_OCI_INDEX    = "application/vnd.oci.image.index.v1+json"

    def initialize(dest_account: ENV.fetch("AWS_ACCOUNT_ID"),
                   dest_region:  ENV.fetch("AWS_REGION", "us-east-2"))
      @dest_account = dest_account
      @dest_region  = dest_region
      @ecr_dest     = Aws::ECR::Client.new(region: @dest_region)
    end

    # Ensures the source image is available in your account/region and returns the DEST URI.
    def ensure_mirrored!(src_uri, dest_repo: nil, dest_tag: nil)
      src = parse_uri(src_uri)
      raise "Invalid ECR URI: #{src_uri}" unless src

      dest_repo ||= src[:repo]
      dest_tag  ||= src[:tag]
      dest_uri    = "#{@dest_account}.dkr.ecr.#{@dest_region}.amazonaws.com/#{dest_repo}:#{dest_tag}"

      # Already present in destination? Done.
      return dest_uri if image_exists?(@ecr_dest, dest_repo, dest_tag)

      # Ensure destination repo exists
      begin
        @ecr_dest.describe_repositories(repository_names: [dest_repo])
      rescue Aws::ECR::Errors::RepositoryNotFoundException
        @ecr_dest.create_repository(repository_name: dest_repo)
      end

      # --- SOURCE LOOKUPS ---
      ecr_src = Aws::ECR::Client.new(region: src[:region])

      # 1) Get top-level manifest (allow manifest AND manifest-list)
      img = ecr_src.batch_get_image(
        registry_id:      src[:account],
        repository_name:  src[:repo],
        image_ids:        [{ image_tag: src[:tag] }],
        accepted_media_types: [MT_DOCKER, MT_OCI, MT_DOCKER_LIST, MT_OCI_INDEX]
      ).images.first or raise "Source image not found: #{src_uri}"

      manifest_json = img.image_manifest
      manifest      = JSON.parse(manifest_json)

      # 2) If multi-arch (manifest list / OCI index), pick linux/amd64 child and fetch its concrete manifest
      if manifest["manifests"].is_a?(Array)
        child = manifest["manifests"].find { |m|
          (m.dig("platform", "os") == "linux") && (m.dig("platform", "architecture") == "amd64")
        } || manifest["manifests"].first

        raise "No suitable child manifest in index" unless child && child["digest"]

        child_img = ecr_src.batch_get_image(
          registry_id:      src[:account],
          repository_name:  src[:repo],
          image_ids:        [{ image_digest: child["digest"] }],
          accepted_media_types: [MT_DOCKER, MT_OCI]
        ).images.first or raise "Child manifest not found for #{child['digest']}"

        manifest_json = child_img.image_manifest
        manifest      = JSON.parse(manifest_json)
      end

      # 3) Collect all blob digests (config + layers)
      digests = []
      digests << manifest.dig("config", "digest")
      (manifest["layers"] || []).each { |l| digests << l["digest"] }
      digests.compact!
      digests.uniq!

      # 4) Upload any missing blobs to destination
      missing = missing_digests(@ecr_dest, dest_repo, digests)
      missing.each do |digest|
        url = ecr_src.get_download_url_for_layer(
          registry_id:     src[:account],
          repository_name: src[:repo],
          layer_digest:    digest
        ).download_url

        upload_blob(@ecr_dest, dest_repo, digest, url)
      end

      # 5) Put the concrete manifest at destination tag
      @ecr_dest.put_image(
        repository_name: dest_repo,
        image_manifest:  manifest_json,
        image_tag:       dest_tag
      )

      dest_uri
    end

    private

    def parse_uri(u)
      m = URI_RE.match(u)
      return nil unless m
      { account: m[:acct], region: m[:region], repo: m[:repo], tag: m[:tag] }
    end

    def image_exists?(ecr, repo, tag)
      ecr.describe_images(repository_name: repo, image_ids: [{ image_tag: tag }])
      true
    rescue Aws::ECR::Errors::ImageNotFoundException, Aws::ECR::Errors::RepositoryNotFoundException
      false
    end

    def missing_digests(ecr, repo, digests)
      resp = ecr.batch_check_layer_availability(
        repository_name: repo,
        layer_digests: digests
      )
      present = Array(resp.layers)
                 .select { |l| l.layer_availability == "AVAILABLE" }
                 .map(&:layer_digest)
      digests - present
    rescue Aws::ECR::Errors::RepositoryNotFoundException
      digests
    end

    # Streams a blob from source URL to destination ECR via multipart upload.
    # We do not need Content-Length in advance; we stream in chunks and maintain byte ranges.
    def upload_blob(ecr, repo, digest, src_url, chunk_size = 8 * 1024 * 1024)
      init       = ecr.initiate_layer_upload(repository_name: repo)
      upload_id  = init.upload_id
      part_first = 0

      URI.open(src_url, "rb") do |io|
        while (data = io.read(chunk_size))
          part_last = part_first + data.bytesize - 1
          ecr.upload_layer_part(
            repository_name: repo,
            upload_id:       upload_id,
            part_first_byte: part_first,
            part_last_byte:  part_last,
            layer_part_blob: data
          )
          part_first = part_last + 1
        end
      end

      ecr.complete_layer_upload(
        repository_name: repo,
        upload_id:       upload_id,
        layer_digests:   [digest] # NOTE: array, not single key
      )
    end
  end
end
