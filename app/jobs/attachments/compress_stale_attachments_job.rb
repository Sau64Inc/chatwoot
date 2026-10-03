require 'image_processing/vips'

# Reclaims disk from old attachments: images are recompressed, videos are replaced by a single frame.
# Destructive and irreversible, so it ships off (ATTACHMENT_COMPRESSION_ENABLED) and has a dry run.
class Attachments::CompressStaleAttachmentsJob < ApplicationJob
  queue_as :housekeeping

  MARKER = 'compression_checked_at'.freeze
  ATTEMPTS = 'compression_attempts'.freeze
  LAST_ERROR = 'compression_error'.freeze
  # A file that fails this many runs is broken (truncated upload, a HEIC sent as video/quicktime),
  # so it gets marked and stops coming back every night.
  MAX_ATTEMPTS = 3
  MIN_GAIN = 0.1
  IMAGE_TYPES = %w[image/jpeg image/png].freeze
  VIDEO_TYPES = %w[video/mp4 video/quicktime video/webm video/x-matroska].freeze

  # dry_run, shards and shard belong to a single run (manual backfill).
  # The cron runs with the defaults and cannot inherit them from the environment.
  def perform(dry_run: false, shards: 1, shard: 0)
    return Rails.logger.info('[compression] disabled (ATTACHMENT_COMPRESSION_ENABLED)') unless enabled?

    @dry_run = dry_run
    @stats = Hash.new(0)
    [VIDEO_TYPES, IMAGE_TYPES].each do |types|
      pending(types, shards, shard).find_each(batch_size: 100) { |attachment| compress(attachment) }
    end
    Rails.logger.info(summary)
  end

  private

  def enabled? = ActiveModel::Type::Boolean.new.cast(ENV.fetch('ATTACHMENT_COMPRESSION_ENABLED', 'false'))
  def stale_after_days = ENV.fetch('ATTACHMENT_COMPRESSION_AFTER_DAYS', '30').to_i
  def batch_limit = ENV.fetch('ATTACHMENT_COMPRESSION_BATCH', '2000').to_i
  def max_dimension = ENV.fetch('ATTACHMENT_IMAGE_MAX_DIMENSION', '1600').to_i
  def quality = ENV.fetch('ATTACHMENT_IMAGE_QUALITY', '75').to_i

  def pending(types, shards, shard)
    scope = Attachment.joins(:file_blob)
                      .where('attachments.created_at < ?', stale_after_days.days.ago)
                      .where(active_storage_blobs: { content_type: types })
                      .where('attachments.meta ->> ? IS NULL', MARKER)
                      .limit(batch_limit)
    shards > 1 ? scope.where('MOD(attachments.id, ?) = ?', shards, shard) : scope
  end

  def compress(attachment)
    blob = attachment.file.blob
    return skip(attachment) unless compressible?(blob)

    output = compressed_file(blob)
    saved = blob.byte_size - output.size
    return skip(attachment) if saved < blob.byte_size * MIN_GAIN

    replace(attachment, blob, output) unless @dry_run
    record(blob.video? ? :videos : :images, saved)
  rescue StandardError => e
    record_failure(attachment, e)
  ensure
    output&.close!
    log_progress
  end

  # An empty file (failed upload) has nothing to shrink and never will.
  def compressible?(blob) = blob.byte_size.positive? && blob.service.exist?(blob.key)

  def replace(attachment, blob, output)
    content_type = blob.video? ? 'image/jpeg' : blob.content_type
    filename = blob.video? ? "#{blob.filename.base}.jpg" : blob.filename.to_s
    new_blob = ActiveStorage::Blob.create_and_upload!(io: output, filename: filename, content_type: content_type)
    attachment.update!(file: new_blob, file_type: :image, meta: marked_meta(attachment))
  end

  # Videos go through Rails' previewer (ffmpeg, a relevant frame with load_defaults 7.0)
  # and from there follow the same path as an image.
  def compressed_file(blob)
    if blob.video?
      ActiveStorage::Previewer::VideoPreviewer.new(blob).preview { |frame| shrink(frame[:io].path, '.jpg') }
    else
      blob.open { |source| shrink(source.path, blob.content_type == 'image/png' ? '.png' : '.jpg') }
    end
  end

  def shrink(path, extension)
    dest = Tempfile.new(['compressed', extension])
    ImageProcessing::Vips.source(path)
                         .resize_to_limit(max_dimension, max_dimension)
                         .saver(quality: quality, strip: true)
                         .call(destination: dest.path)
    dest
  end

  # Skips are marked too, or those ids take up the batch quota every night.
  def skip(attachment)
    @stats[:skipped] += 1
    attachment.update!(meta: marked_meta(attachment)) unless @dry_run
  end

  # Counted rather than marked on the first error: a missing binary or a full disk fails every
  # file for a night and must not shelve them all. Reloaded first because a failed replace
  # leaves unsaved changes on the record that update! would otherwise persist.
  def record_failure(attachment, error)
    @stats[:errors] += 1
    Rails.logger.error("[compression] attachment #{attachment.id}: #{error.class} #{error.message}")
    return if @dry_run

    attachment.reload
    attempts = attachment.meta.fetch(ATTEMPTS, 0) + 1
    meta = attachment.meta.merge(ATTEMPTS => attempts, LAST_ERROR => "#{error.class}: #{error.message.lines.last&.strip}".truncate(200))
    meta[MARKER] = Time.current.iso8601 if attempts >= MAX_ATTEMPTS
    attachment.update!(meta: meta)
  end

  def marked_meta(attachment) = attachment.meta.except(ATTEMPTS, LAST_ERROR).merge(MARKER => Time.current.iso8601)

  def record(kind, saved)
    @stats[kind] += 1
    @stats[:freed] += [saved, 0].max
  end

  def log_progress
    @stats[:seen] += 1
    return unless (@stats[:seen] % 200).zero?

    Rails.logger.info("[compression] #{@stats[:seen]} processed, #{gb(@stats[:freed])} GB freed")
  end

  def summary
    "[compression] #{@dry_run ? 'DRY RUN' : 'applied'} · #{@stats[:videos]} videos, #{@stats[:images]} images, " \
      "#{@stats[:skipped]} skipped, #{@stats[:errors]} errors, #{gb(@stats[:freed])} GB freed"
  end

  def gb(bytes)
    (bytes / (1024.0**3)).round(2)
  end
end
