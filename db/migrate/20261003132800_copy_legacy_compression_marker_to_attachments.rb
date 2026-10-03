class CopyLegacyCompressionMarkerToAttachments < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE attachments
      SET meta = COALESCE(attachments.meta, '{}'::jsonb)
                 || jsonb_build_object('compression_checked_at', blobs.metadata::jsonb ->> 'compressed_at')
      FROM active_storage_attachments asa
      JOIN active_storage_blobs blobs ON blobs.id = asa.blob_id
      WHERE asa.record_type = 'Attachment'
        AND asa.name = 'file'
        AND asa.record_id = attachments.id
        AND blobs.metadata::jsonb ? 'compressed_at'
        AND NOT COALESCE(attachments.meta, '{}'::jsonb) ? 'compression_checked_at'
    SQL
  end

  def down
    # no-op: the legacy key stays on the blobs, so nothing is lost
  end
end
