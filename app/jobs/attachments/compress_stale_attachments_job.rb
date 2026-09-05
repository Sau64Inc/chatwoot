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

    adjuntar_marcado(adjunto, salida.path, "#{File.basename(blob.filename.to_s, '.*')}.jpg", 'image/jpeg')
    # Sin esto la UI sigue pintando un reproductor de video.
    adjunto.update!(file_type: :image)
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

    adjuntar_marcado(adjunto, salida.path, blob.filename.to_s, blob.content_type)
    registrar(:imagenes, ahorro)
  ensure
    salida&.close!
  end

  # Se llama a `magick` directo y no a ImageProcessing::MiniMagick a proposito.
  #
  # ImageProcessing arma el comando como `magick convert ...`, que es la forma
  # vieja, y ImageMagick 7 escupe un warning por cada archivo:
  #   "The convert command is deprecated in IMv7, use magick instead"
  # Sobre 46.000 imagenes son 46.000 lineas de ruido en el log, tapando
  # cualquier error de verdad. Llamando al binario como corresponde el warning
  # no existe, y de paso se saca una capa de indireccion: la rama de video ya
  # invoca ffmpeg de esta misma manera.
  #
  # El `>` de "1600x1600>" es de ImageMagick, no del shell: significa "achica
  # solo si es mas grande". Como se pasa por argumentos y no por una shell, no
  # hay redireccion que valga.
  def achicar(blob)
    lado = ENV.fetch('ATTACHMENT_IMAGE_MAX_DIMENSION', 1600).to_i
    calidad = ENV.fetch('ATTACHMENT_IMAGE_QUALITY', 75).to_i
    destino = Tempfile.new(['comprimida', extension(blob)])
    ok = blob.open do |origen|
      system('magick', origen.path, '-auto-orient', '-resize', "#{lado}x#{lado}>",
             '-strip', '-quality', calidad.to_s, destino.path)
    end
    return destino if ok && destino.size.positive?

    destino.close!
    nil
  rescue StandardError => e
    Rails.logger.warn("[compresion] no pude achicar el blob #{blob.id}: #{e.message}")
    nil
  end

  def extension(blob)
    blob.content_type == 'image/png' ? '.png' : '.jpg'
  end

  # ----------------------------------------------------------------- comun ---
  # Crea el blob YA MARCADO y recien despues lo adjunta.
  #
  # Marcar despues del attach no sirve: Active Storage encola su propio
  # AnalyzeJob al adjuntar, ese job escribe ancho/alto/analyzed en el metadata
  # con un read-modify-write, y si cargo la fila antes de que se escribiera la
  # marca, la pisa. Medido en la primera corrida: de 14.119 blobs nuevos, solo
  # 403 conservaron la marca. Sin marca, la foto se vuelve a comprimir en la
  # corrida siguiente, y cada noche pierde un poco mas de calidad.
  #
  # Con la marca puesta en el INSERT no hay ventana: cualquier lectura posterior
  # —la del AnalyzeJob incluida, que carga fresco de la base— ya la ve, y su
  # merge la conserva.
  def adjuntar_marcado(adjunto, ruta, nombre, tipo)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(ruta), filename: nombre, content_type: tipo,
      metadata: { MARCA => Time.current.iso8601 }
    )
    adjunto.file.attach(blob)
    blob
  end

  # Para el caso en que NO se reemplaza el archivo (la imagen no daba ganancia):
  # aca no hay attach, no hay AnalyzeJob nuevo y por lo tanto no hay carrera.
  def marcar(blob)
    blob.update!(metadata: blob.metadata.merge(MARCA => Time.current.iso8601))
  end

  def registrar(clave, ahorro)
    @stats[clave] += 1
    @stats[:liberado] += [ahorro, 0].max
  end
end
