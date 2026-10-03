require 'rails_helper'

RSpec.describe Attachments::CompressStaleAttachmentsJob do
  let(:message) { create(:message) }
  let(:marker) { described_class::MARKER }

  around do |example|
    with_modified_env(ATTACHMENT_COMPRESSION_ENABLED: 'true', ATTACHMENT_IMAGE_MAX_DIMENSION: '100') { example.run }
  end

  def stale_attachment(filename, content_type, file_type, created_at: 40.days.ago, io: nil)
    attachment = message.attachments.new(account_id: message.account_id, file_type: file_type, created_at: created_at)
    io ||= Rails.root.join("spec/assets/#{filename}").open
    attachment.file.attach(io: io, filename: filename, content_type: content_type)
    attachment.save!
    attachment
  end

  it 'enqueues the job on the housekeeping queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('housekeeping')
  end

  it 'does nothing when disabled' do
    attachment = stale_attachment('sample.png', 'image/png', :image)
    blob_id = attachment.file.blob.id

    with_modified_env(ATTACHMENT_COMPRESSION_ENABLED: 'false') { described_class.perform_now }

    expect(attachment.reload.file.blob.id).to eq(blob_id)
    expect(attachment.meta).not_to have_key(marker)
  end

  it 'leaves recent attachments alone' do
    attachment = stale_attachment('sample.png', 'image/png', :image, created_at: Time.current)
    blob_id = attachment.file.blob.id

    described_class.perform_now

    expect(attachment.reload.file.blob.id).to eq(blob_id)
    expect(attachment.meta).not_to have_key(marker)
  end

  it 'recompresses a stale image and purges the original blob' do
    attachment = stale_attachment('sample.png', 'image/png', :image)
    old_blob = attachment.file.blob

    perform_enqueued_jobs { described_class.perform_now }

    new_blob = attachment.reload.file.blob
    expect(new_blob.id).not_to eq(old_blob.id)
    expect(new_blob.byte_size).to be < old_blob.byte_size
    expect(new_blob.content_type).to eq('image/png')
    expect(attachment.file_type).to eq('image')
    expect(attachment.meta[marker]).to be_present
    expect { old_blob.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'replaces a stale video with a jpeg frame' do
    attachment = stale_attachment('sample.mp4', 'video/mp4', :video)

    described_class.perform_now

    blob = attachment.reload.file.blob
    expect(blob.content_type).to eq('image/jpeg')
    expect(blob.filename.to_s).to eq('sample.jpg')
    expect(attachment.file_type).to eq('image')
    expect(attachment.meta[marker]).to be_present
  end

  it 'marks without rewriting when the gain is below the threshold' do
    attachment = stale_attachment('sample.png', 'image/png', :image)
    described_class.perform_now
    attachment.reload.update!(meta: {})
    blob_id = attachment.file.blob.id

    described_class.perform_now

    expect(attachment.reload.file.blob.id).to eq(blob_id)
    expect(attachment.meta[marker]).to be_present
  end

  it 'touches nothing on a dry run' do
    attachment = stale_attachment('sample.png', 'image/png', :image)
    blob_id = attachment.file.blob.id

    described_class.perform_now(dry_run: true)

    expect(attachment.reload.file.blob.id).to eq(blob_id)
    expect(attachment.meta).not_to have_key(marker)
  end

  it 'logs an error and leaves the attachment unmarked when ffmpeg is missing' do
    attachment = stale_attachment('sample.mp4', 'video/mp4', :video)
    blob_id = attachment.file.blob.id
    allow(ActiveStorage::Previewer::VideoPreviewer).to receive(:ffmpeg_path).and_return('/nonexistent/ffmpeg')
    allow(Rails.logger).to receive(:error)

    described_class.perform_now

    expect(attachment.reload.file.blob.id).to eq(blob_id)
    expect(attachment.meta).not_to have_key(marker)
    expect(Rails.logger).to have_received(:error).with(/attachment \d+: Errno::ENOENT/)
  end

  it 'marks an empty file without trying to compress it' do
    attachment = stale_attachment('empty.jpg', 'image/jpeg', :image, io: StringIO.new)
    blob_id = attachment.file.blob.id
    allow(Rails.logger).to receive(:error)

    described_class.perform_now

    expect(attachment.reload.file.blob.id).to eq(blob_id)
    expect(attachment.meta[marker]).to be_present
    expect(Rails.logger).not_to have_received(:error)
  end

  it 'marks a broken file once it has failed MAX_ATTEMPTS runs' do
    attachment = stale_attachment('broken.jpg', 'image/jpeg', :image, io: StringIO.new('not an image'))
    allow(Rails.logger).to receive(:error)

    described_class.perform_now(dry_run: true)
    expect(attachment.reload.meta).not_to have_key(described_class::ATTEMPTS)

    (described_class::MAX_ATTEMPTS - 1).times { described_class.perform_now }
    expect(attachment.reload.meta).not_to have_key(marker)
    expect(attachment.meta[described_class::ATTEMPTS]).to eq(described_class::MAX_ATTEMPTS - 1)

    described_class.perform_now

    expect(attachment.reload.meta[marker]).to be_present
    expect(attachment.meta[described_class::LAST_ERROR]).to start_with('Vips::Error')
  end

  it 'only processes the ids of its shard' do
    attachments = Array.new(2) { stale_attachment('sample.png', 'image/png', :image) }

    described_class.perform_now(shards: 2, shard: 0)

    attachments.each do |attachment|
      expect(attachment.reload.meta.key?(marker)).to eq(attachment.id.even?)
    end
  end
end
