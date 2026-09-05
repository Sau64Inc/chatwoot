# Shrinks old attachments instead of deleting them.
#
#   images -> recompressed and capped at ATTACHMENT_IMAGE_MAX_DIMENSION
#   videos -> replaced by a single frame, and the attachment becomes an image
#
# The target is disk usage: in our installation videos are 12% of the files and
# 68% of the space. Replacing them with a frame turns 194 GB into about 4 GB,
# and recompressing the images takes away roughly half of what is left.
#
# WHAT TO KNOW BEFORE TURNING IT ON
#
#   It is destructive and cannot be undone. The original video is replaced and
#   no copy is kept. That is why it ships off by default (ATTACHMENT_COMPRESSION_ENABLED)
#   and has a dry-run mode that reports how much it would free without touching anything.
#
#   A processed attachment is marked in `blob.metadata` so it is not reprocessed
#   every night. The mark goes on the NEW blob, which is the one that stays attached.
#
#   When replacing a video, `file_type` has to move to :image. Otherwise the UI
#   keeps rendering a video player with a JPG inside it.
class Attachments::CompressStaleAttachmentsJob < ApplicationJob
  queue_as :housekeeping

  MARKER = 'compressed_at'.freeze
  # gif is left out on purpose: recompressing it collapses it to a single frame
  # and loses the animation. tiff and svg too, they are a handful of files and
  # not worth the risk. heic/heif are left out: alpine's imagemagick ships
  # without the HEIC delegate and fails with "no decode delegate". They are
  # 900 MB of the total, not enough to justify adding libheif to the build.
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

  # Cap per type per run, so a single night does not run forever.
  def batch_limit
    ENV.fetch('ATTACHMENT_COMPRESSION_BATCH', 2000).to_i
  end

  def max_dimension
    ENV.fetch('ATTACHMENT_IMAGE_MAX_DIMENSION', 1600).to_i
  end

  # Attachments older than the window that have not been processed yet.
  # The marker lives in the blob metadata so no migration is needed.
  # Optional sharding, meant for the initial backfill: N processes, each with its
  # own remainder of the division. Since each one touches a disjoint set of ids,
  # there is no coordination, no locks, and no two processes fighting over the
  # same attachment.
  #
  # Defaults to 1 shard, i.e. exactly the usual behavior: the daily cron does not
  # need this and does not use it.
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
                # `metadata` is a TEXT column with JSON inside, that is how Active
                # Storage defines it. Without the jsonb cast the ->> operator does
                # not exist and postgres bails with "operator does not exist:
                # text ->> unknown".
                .where("COALESCE(active_storage_blobs.metadata, '{}')::jsonb ->> ? IS NULL", MARKER)
    ).limit(batch_limit)
  end

  def process_batch(scope, kind)
    scope.find_each(batch_size: 100) do |attachment|
      blob = attachment.file.blob
      # If the file is gone there is nothing to compress. Cleaning up rows
      # without a file is a different problem, not this job's.
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
    # Without this the UI keeps rendering a video player.
    attachment.update!(file_type: :image)
    record(:videos, saved)
  ensure
    output&.close!
  end

  # ffmpeg is not in chatwoot's base image: it is added in docker/Dockerfile.
  #
  # The frame instant is configurable because second zero of a video shot on a
  # phone is usually black, and a black thumbnail is useless.
  def extract_frame(blob)
    dest = Tempfile.new(['frame', '.jpg'])
    blob.open do |source|
      # Same cap as images: force_original_aspect_ratio=decrease fits inside the
      # box without distortion, and min() against iw/ih avoids upscaling a video
      # that was already small.
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
    # If it does not save at least 10% it is not worth rewriting the blob nor
    # losing quality. Mark it anyway so it is not retried every night.
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

  # `magick` is called directly rather than through ImageProcessing::MiniMagick
  # on purpose.
  #
  # ImageProcessing builds the command as `magick convert ...`, the old form, and
  # ImageMagick 7 prints a warning per file:
  #   "The convert command is deprecated in IMv7, use magick instead"
  # Over 46,000 images that is 46,000 lines of noise in the log, burying any real
  # error. Calling the binary the right way the warning is gone, and it drops a
  # layer of indirection: the video branch already invokes ffmpeg the same way.
  #
  # The `>` in "1600x1600>" is ImageMagick's, not the shell's: it means "shrink
  # only if larger". Since it is passed as an argument and not through a shell,
  # there is no redirection at play.
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
  # Creates the blob ALREADY MARKED and only then attaches it.
  #
  # Marking after the attach does not work: Active Storage enqueues its own
  # AnalyzeJob on attach, that job writes width/height/analyzed into the metadata
  # with a read-modify-write, and if it loads the row before the mark was written
  # it overwrites it. Measured on the first run: out of 14,119 new blobs, only 403
  # kept the mark. Without the mark the image is recompressed on the next run, and
  # every night it loses a bit more quality.
  #
  # With the mark set on the INSERT there is no window: any later read (the
  # AnalyzeJob's included, which loads fresh from the database) already sees it,
  # and its merge preserves it.
  #
  # The io is rewound and reused instead of reopening the path, so no extra file
  # descriptor leaks across a run of tens of thousands of attachments.
  def attach_marked(attachment, io, filename, content_type)
    io.rewind
    blob = ActiveStorage::Blob.create_and_upload!(
      io: io, filename: filename, content_type: content_type,
      metadata: { MARKER => Time.current.iso8601 }
    )
    attachment.file.attach(blob)
    blob
  end

  # For the case where the file is NOT replaced (the image had no gain): there is
  # no attach here, no new AnalyzeJob and therefore no race.
  def mark(blob)
    blob.update!(metadata: blob.metadata.merge(MARKER => Time.current.iso8601))
  end

  # A full run is tens of thousands of attachments: without a line every so often
  # there is no way to tell "making progress" from "hung".
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
