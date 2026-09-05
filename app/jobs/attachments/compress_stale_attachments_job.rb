# Reclaims disk from old attachments instead of deleting them: images are
# recompressed, videos are replaced by a single frame (file_type moves to :image,
# or the UI renders a video player around a JPG).
#
# Destructive and irreversible, so it ships off by default with a dry-run mode.
# Processed blobs are marked in blob.metadata so they are not reprocessed nightly.
class Attachments::CompressStaleAttachmentsJob < ApplicationJob
  queue_as :housekeeping

  MARKER = 'compressed_at'.freeze
  # gif/tiff/svg excluded (recompressing kills gif animation, the rest are a
  # handful of files). heic excluded: alpine's imagemagick lacks the HEIC delegate.
  IMAGE_TYPES = ['image/jpeg', 'image/png'].freeze
  VIDEO_TYPES = ['video/mp4', 'video/quicktime', 'video/webm', 'video/x-matroska'].freeze

  def perform
    return Rails.logger.info('[compression] disabled (ATTACHMENT_COMPRESSION_ENABLED)') unless enabled?

    @stats = Hash.new(0)
    process_batch(pending(VIDEO_TYPES), :video)
    process_batch(pending(IMAGE_TYPES), :image)
    Rails.logger.info(
      "[compression] #{dry_run? ? 'DRY RUN' : 'applied'} · #{@stats[:videos]} videos, " \
      "#{@stats[:images]} images, #{@stats[:skipped]} skipped, " \
      "#{@stats[:errors]} errors, #{gb(@stats[:freed])} GB freed"
    )
  end

  private

  def enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ATTACHMENT_COMPRESSION_ENABLED', false))
  end

  def dry_run?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ATTACHMENT_COMPRESSION_DRY_RUN', false))
  end

  def stale_after_days
    ENV.fetch('ATTACHMENT_COMPRESSION_AFTER_DAYS', 30).to_i
  end

  # Cap per type per run.
  def batch_limit
    ENV.fetch('ATTACHMENT_COMPRESSION_BATCH', 2000).to_i
  end

  def max_dimension
    ENV.fetch('ATTACHMENT_IMAGE_MAX_DIMENSION', 1600).to_i
  end

  # Optional sharding for the initial backfill only: N processes each take a
  # disjoint id remainder, no locks needed. Defaults to 1 (no-op), the cron uses that.
  def apply_shard(scope)
    shards = ENV.fetch('ATTACHMENT_COMPRESSION_SHARDS', 1).to_i
    return scope if shards <= 1

    scope.where('MOD(attachments.id, ?) = ?', shards, ENV.fetch('ATTACHMENT_COMPRESSION_SHARD', 0).to_i)
  end

  def pending(types)
    apply_shard(
      Attachment.joins(file_attachment: :blob)
                .where('attachments.created_at < ?', stale_after_days.days.ago)
                .where(active_storage_blobs: { content_type: types })
                # metadata is a TEXT column, cast to jsonb or the ->> operator does not exist.
                .where("COALESCE(active_storage_blobs.metadata, '{}')::jsonb ->> ? IS NULL", MARKER)
    ).limit(batch_limit)
  end

  def process_batch(scope, kind)
    scope.find_each(batch_size: 100) do |attachment|
      blob = attachment.file.blob
      # A missing file is a different problem, not this job's.
      next @stats[:skipped] += 1 unless file_present?(blob)

      kind == :video ? convert_video(attachment, blob) : recompress_image(attachment, blob)
      @stats[:seen] += 1
      log_progress
    rescue StandardError => e
      @stats[:errors] += 1
      Rails.logger.error("[compression] attachment #{attachment.id}: #{e.class} #{e.message}")
    end
  end

  def file_present?(blob)
    blob.service.exist?(blob.key)
  end

  # ------------------------------------------------------------------ video --
  def convert_video(attachment, blob)
    output = extract_frame(blob)
    return @stats[:skipped] += 1 if output.nil?

    saved = blob.byte_size - output.size
    return record(:videos, saved) if dry_run?

    attach_marked(attachment, output, "#{File.basename(blob.filename.to_s, '.*')}.jpg", 'image/jpeg')
    # Or the UI keeps rendering a video player around the JPG.
    attachment.update!(file_type: :image)
    record(:videos, saved)
  ensure
    output&.close!
  end

  # ffmpeg is added in docker/Dockerfile. The frame instant is configurable
  # because second zero is often black on phone videos.
  def extract_frame(blob)
    dest = Tempfile.new(['frame', '.jpg'])
    blob.open do |source|
      # cap to max_dimension without upscaling or distorting
      scale = "scale='min(#{max_dimension},iw)':'min(#{max_dimension},ih)':force_original_aspect_ratio=decrease"
      system('ffmpeg', '-loglevel', 'error', '-y', '-ss', ENV.fetch('ATTACHMENT_VIDEO_FRAME_AT', '00:00:01'),
             '-i', source.path, '-frames:v', '1', '-vf', scale, '-q:v', '3', '-f', 'image2', dest.path)
    end
    dest.size.positive? ? dest : (dest.close! && nil)
  end

  # --------------------------------------------------------------- images --
  def recompress_image(attachment, blob)
    output = shrink(blob)
    return @stats[:skipped] += 1 if output.nil?

    saved = blob.byte_size - output.size
    # Below 10% gain it is not worth rewriting or losing quality. Mark it so it is not retried.
    if saved < blob.byte_size * 0.1
      mark(blob) unless dry_run?
      return @stats[:skipped] += 1
    end
    return record(:images, saved) if dry_run?

    attach_marked(attachment, output, blob.filename.to_s, blob.content_type)
    record(:images, saved)
  ensure
    output&.close!
  end

  # magick is called directly (not through ImageProcessing) to avoid the
  # deprecated `magick convert` form, which logs a warning per file.
  def shrink(blob)
    quality = ENV.fetch('ATTACHMENT_IMAGE_QUALITY', 75).to_i
    dest = Tempfile.new(['compressed', extension_for(blob)])
    ok = blob.open do |source|
      system('magick', source.path, '-auto-orient', '-resize', "#{max_dimension}x#{max_dimension}>",
             '-strip', '-quality', quality.to_s, dest.path)
    end
    return dest if ok && dest.size.positive?

    dest.close!
    nil
  rescue StandardError => e
    Rails.logger.warn("[compression] could not shrink blob #{blob.id}: #{e.message}")
    nil
  end

  def extension_for(blob)
    blob.content_type == 'image/png' ? '.png' : '.jpg'
  end

  # ----------------------------------------------------------------- shared --
  # Create the blob already marked, then attach. Active Storage's AnalyzeJob does a
  # read-modify-write on metadata after attach and would clobber a mark written
  # later, so it goes on the INSERT to survive that merge. The io is rewound and
  # reused rather than reopened, so no fd leaks across a large run.
  def attach_marked(attachment, io, filename, content_type)
    io.rewind
    blob = ActiveStorage::Blob.create_and_upload!(
      io: io, filename: filename, content_type: content_type,
      metadata: { MARKER => Time.current.iso8601 }
    )
    attachment.file.attach(blob)
    blob
  end

  # No attach here, so no AnalyzeJob race: a plain merge is safe.
  def mark(blob)
    blob.update!(metadata: blob.metadata.merge(MARKER => Time.current.iso8601))
  end

  def log_progress
    return unless (@stats[:seen] % 200).zero?

    Rails.logger.info("[compression] #{@stats[:seen]} processed, #{gb(@stats[:freed])} GB freed")
  end

  def gb(bytes)
    (bytes / (1024.0**3)).round(2)
  end

  def record(key, saved)
    @stats[key] += 1
    @stats[:freed] += [saved, 0].max
  end
end
