# Achica los adjuntos viejos en vez de borrarlos.
#
#   imagenes -> se recomprimen y se limitan a ATTACHMENT_IMAGE_MAX_DIMENSION
#   videos   -> se reemplazan por un frame, y el adjunto pasa a ser una imagen
#
# El objetivo es el disco: en nuestra instalacion los videos son el 12% de los
# archivos y el 68% del espacio. Reemplazarlos por un frame convierte 194 GB en
# unos 4 GB, y recomprimir las imagenes se lleva otra mitad de lo que queda.
#
# LO QUE HAY QUE SABER ANTES DE PRENDERLO
#
#   Es destructivo y no se puede deshacer. El video original se reemplaza; no
#   queda copia. Por eso viene apagado de fabrica (ATTACHMENT_COMPRESSION_ENABLED)
#   y tiene un modo de simulacion que informa cuanto liberaria sin tocar nada.
#
#   Un adjunto procesado se marca en `blob.metadata` para no volver a pasarle por
#   arriba todas las noches. La marca va en el blob NUEVO, que es el que queda
#   attacheado.
#
#   Al reemplazar un video hay que mover `file_type` a :image. Si no, la interfaz
#   sigue mostrando un reproductor de video con un JPG adentro.
class Attachments::CompressStaleAttachmentsJob < ApplicationJob
  queue_as :housekeeping

  MARCA = 'compressed_at'.freeze
  # gif queda afuera a proposito: recomprimirlo lo deja en un solo cuadro y se
  # pierde la animacion. tiff y svg tampoco, son cuatro archivos y no vale el riesgo.
  # heic/heif quedan afuera: la imagemagick de alpine viene sin el delegado de
  # HEIC y falla con "no decode delegate". Son 900 MB del total, no justifican
  # meter libheif en el build.
  IMAGENES = ['image/jpeg', 'image/png'].freeze
  VIDEOS = ['video/mp4', 'video/quicktime', 'video/webm', 'video/x-matroska'].freeze

  def perform
    return Rails.logger.info('[compresion] deshabilitada (ATTACHMENT_COMPRESSION_ENABLED)') unless habilitado?

    @stats = Hash.new(0)
    procesar(pendientes(VIDEOS), :video)
    procesar(pendientes(IMAGENES), :imagen)
    Rails.logger.info(
      "[compresion] #{simular? ? 'SIMULACION' : 'aplicado'} · #{@stats[:videos]} videos, " \
      "#{@stats[:imagenes]} imagenes, #{@stats[:saltados]} saltados, #{@stats[:errores]} errores, " \
      "#{(@stats[:liberado] / 1024.0**3).round(2)} GB liberados"
    )
  end

  private

  def habilitado?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ATTACHMENT_COMPRESSION_ENABLED', false))
  end

  def simular?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ATTACHMENT_COMPRESSION_DRY_RUN', false))
  end

  def dias
    ENV.fetch('ATTACHMENT_COMPRESSION_AFTER_DAYS', 30).to_i
  end

  def lote
    ENV.fetch('ATTACHMENT_COMPRESSION_BATCH', 2000).to_i
  end

  # Los adjuntos mas viejos que la ventana, que todavia no pasaron por aca.
  # La marca vive en el metadata del blob para no necesitar una migracion.
  def pendientes(tipos)
    Attachment.joins(file_attachment: :blob)
              .where('attachments.created_at < ?', dias.days.ago)
              .where(active_storage_blobs: { content_type: tipos })
              # `metadata` es una columna de TEXTO con JSON adentro, asi la define
              # Active Storage. Sin el cast a jsonb el operador ->> no existe y
              # postgres corta con "operator does not exist: text ->> unknown".
              .where("COALESCE(active_storage_blobs.metadata, '{}')::jsonb ->> ? IS NULL", MARCA)
              .limit(lote)
  end

  def procesar(scope, clase)
    scope.find_each(batch_size: 100) do |adjunto|
      blob = adjunto.file.blob
      # Si el archivo no esta, no hay nada que comprimir. Lo de arreglar las
      # filas sin archivo es otro problema y no es el de este job.
      next @stats[:saltados] += 1 unless archivo_presente?(blob)

      clase == :video ? convertir_video(adjunto, blob) : recomprimir_imagen(adjunto, blob)
      @stats[:vistos] += 1
      if (@stats[:vistos] % 200).zero?
        Rails.logger.info("[compresion] #{@stats[:vistos]} procesados, "                           "#{(@stats[:liberado] / 1024.0**3).round(2)} GB liberados")
      end
    rescue StandardError => e
      @stats[:errores] += 1
      Rails.logger.error("[compresion] adjunto #{adjunto.id}: #{e.class} #{e.message}")
    end
  end

  def archivo_presente?(blob)
    blob.service.exist?(blob.key)
  end

  # ------------------------------------------------------------------ video --
  def convertir_video(adjunto, blob)
    salida = extraer_frame(blob)
    return @stats[:saltados] += 1 if salida.nil?

    ahorro = blob.byte_size - salida.size
    return registrar(:videos, ahorro) if simular?

    adjunto.file.attach(io: File.open(salida.path), content_type: 'image/jpeg',
                        filename: "#{File.basename(blob.filename.to_s, '.*')}.jpg")
    # Sin esto la UI sigue pintando un reproductor de video.
    adjunto.update!(file_type: :image)
    marcar(adjunto.reload.file.blob)
    registrar(:videos, ahorro)
  ensure
    salida&.close!
  end

  # ffmpeg no viene en la imagen base de chatwoot: se agrega en docker/Dockerfile.
  #
  # El instante del frame es configurable porque el segundo cero de un video
  # filmado con celular suele ser negro, y un thumbnail negro no sirve de nada.
  def extraer_frame(blob)
    destino = Tempfile.new(['frame', '.jpg'])
    blob.open do |origen|
      # El mismo tope que las imagenes: force_original_aspect_ratio=decrease
      # entra en la caja sin deformar, y el min() con iw/ih evita agrandar un
      # video que ya era chico.
      lado = ENV.fetch('ATTACHMENT_IMAGE_MAX_DIMENSION', 1600).to_i
      escala = "scale='min(#{lado},iw)':'min(#{lado},ih)':force_original_aspect_ratio=decrease"
      system('ffmpeg', '-loglevel', 'error', '-y', '-ss', ENV.fetch('ATTACHMENT_VIDEO_FRAME_AT', '00:00:01'),
             '-i', origen.path, '-frames:v', '1', '-vf', escala, '-q:v', '3', '-f', 'image2', destino.path)
    end
    destino.size.positive? ? destino : (destino.close! && nil)
  end

  # --------------------------------------------------------------- imagenes --
  def recomprimir_imagen(adjunto, blob)
    salida = achicar(blob)
    return @stats[:saltados] += 1 if salida.nil?

    ahorro = blob.byte_size - File.size(salida.path)
    # Si no se gana al menos un 10%, no vale la pena reescribir el blob ni
    # perder calidad. Se marca igual para no volver a intentarlo cada noche.
    if ahorro < blob.byte_size * 0.1
      marcar(blob) unless simular?
      return @stats[:saltados] += 1
    end
    return registrar(:imagenes, ahorro) if simular?

    adjunto.file.attach(io: File.open(salida.path), filename: blob.filename.to_s,
                        content_type: blob.content_type)
    marcar(adjunto.reload.file.blob)
    registrar(:imagenes, ahorro)
  ensure
    salida&.close!
  end

  def achicar(blob)
    lado = ENV.fetch('ATTACHMENT_IMAGE_MAX_DIMENSION', 1600).to_i
    calidad = ENV.fetch('ATTACHMENT_IMAGE_QUALITY', 75).to_i
    blob.open do |origen|
      ImageProcessing::MiniMagick.source(origen.path)
                                 .resize_to_limit(lado, lado)
                                 .saver(quality: calidad, strip: true)
                                 .call
    end
  rescue StandardError => e
    Rails.logger.warn("[compresion] no pude achicar el blob #{blob.id}: #{e.message}")
    nil
  end

  # ----------------------------------------------------------------- comun ---
  def marcar(blob)
    blob.update!(metadata: blob.metadata.merge(MARCA => Time.current.iso8601))
  end

  def registrar(clave, ahorro)
    @stats[clave] += 1
    @stats[:liberado] += [ahorro, 0].max
  end
end
