# Foco

Grabador personal nativo para macOS 15 o posterior, con interfaz en blanco, negro y grises neutros. La compilación incluida está destinada a Macs con Apple Silicon.

## Usar

1. Abre `Foco.app`.
2. Elige la pantalla en la barra superior y activa cámara, micrófono y audio del Mac desde los botones de la barra inferior. La **vista previa en vivo** muestra la pantalla y la cámara antes de grabar; cambia al elegir otra pantalla o esquina de cámara. Si faltan permisos, pulsa **Activar vista previa** y autoriza la pantalla y, si está activada, la cámara. Puedes desactivar Cámara para previsualizar solo la pantalla.
3. Pulsa **Grabar** cuando estés listo. Hasta entonces no se crea ningún archivo, no se captura audio y el contador permanece en 00:00. macOS solicitará los permisos de grabación que todavía falten. Si te pide reiniciar la aplicación después de concederlos, vuelve a abrirla.
4. La grabación empieza en cuanto se preparan los dispositivos, sin cuenta regresiva ni espera añadida de tres segundos. Puedes minimizar Foco: sigue funcionando y aparece un control de grabación en la barra de menús.
5. Usa **Pausar** para interrumpir la grabación. El mismo botón cambia a **Reanudar** y continúa en el mismo archivo. El contador se congela y el tiempo en pausa se elimina del video y del audio. También puedes usar **⇧⌘P** con Foco activo o el menú de la barra superior.
6. Pulsa **Detener** en la ventana o **Detener y guardar** en el menú de la barra superior. Puedes hacerlo incluso durante una pausa. Cuando termine de guardar el MP4, Foco abre automáticamente su editor en la misma ventana.

El botón **Pantalla** cambia a **Solo cámara**: desactiva la imagen de pantalla y la cámara llena el encuadre, espejada y sin deformarse. Se recortan los lados que sobren para llenar el video. Pulsa **Solo cámara** para volver a la pantalla; la cámara recupera su posición anterior. Puedes cambiar antes de grabar o durante la misma grabación si la cámara estaba activada al comenzar. En modo Solo cámara no se puede apagar la cámara y dejar el video sin ninguna fuente. La resolución del archivo permanece fija y los cambios quedan en el mismo MP4.

La vista previa de Solo cámara funciona sin permiso de pantalla. Para grabar únicamente cámara y micrófono, desactiva **Audio** si no necesitas el sonido del Mac: así tampoco se abre una captura de pantalla para el audio del sistema. Si Audio está activado, ScreenCaptureKit solo entrega audio mientras Pantalla está desactivada. La cámara utiliza su resolución disponible (preferentemente 1080p) y 60 fps cuando el dispositivo lo admite; llenar el encuadre nativo no añade detalle que la cámara no tenga.

Durante una pausa no se escriben imágenes ni audio al archivo y la vista previa queda congelada. Los dispositivos de captura pueden seguir activos para poder reanudar inmediatamente; se liberan al detener la grabación.

La vista previa ocupa el espacio central y crece con la ventana; el botón de las flechas de arriba a la derecha activa la pantalla completa. Utiliza un objetivo de 60 fps antes y durante la grabación, igual que el video final. La frecuencia efectiva depende de la pantalla, la cámara y la carga del Mac; las fuentes estáticas reutilizan su última imagen. Antes de grabar, libera la pantalla y la cámara al minimizar, ocultar la ventana o abrir el editor. Al volver, se activa de nuevo. La grabación conserva la resolución nativa del modo de pantalla de macOS a 60 fps, sin selector de calidad ni reducción a 1080p.

Para **mover la cámara**, arrastra su imagen con el mouse dentro de la vista previa. Funciona antes y durante la grabación, con posición libre y límites que impiden sacarla del video. Los movimientos durante la grabación quedan en el archivo desde ese momento; no alteran lo ya grabado. En Ajustes puedes volver rápidamente a cualquiera de las cuatro esquinas. Durante una pausa, la imagen y la posición permanecen congeladas.

## Recortar y exportar

El editor permite únicamente elegir el inicio y el fin del video, previsualizar el fragmento y exportarlo. Ajusta los extremos de la línea de tiempo y pulsa **Exportar** para elegir el nombre y la carpeta. La exportación crea otra copia y conserva la grabación original.

Se utiliza exportación passthrough: conserva los datos comprimidos del video y el audio, la resolución y los fotogramas por segundo, sin volver a comprimir. Los cortes entre fotogramas clave utilizan la información de decodificación necesaria en el contenedor MP4 para mantener la calidad. Si un archivo no admite este tipo de exportación, Foco muestra un error en lugar de reducir la calidad silenciosamente.

Puedes cancelar la exportación. El archivo de destino solo se reemplaza después de completar el proceso si aceptaste reemplazarlo en el diálogo de guardado. Nunca se reemplaza la grabación original. **Volver a grabar** vuelve a la vista de captura. Para recortar una grabación anterior, usa **Abrir video para recortar…** (⌘O), o **Recortar última grabación** en Ajustes.

Los archivos se guardan por defecto en `~/Movies/Foco`. Abre **Ajustes**, en el icono de controles de la barra superior, para cambiar la carpeta o la esquina de la cámara. El icono de carpeta abre tus grabaciones. La cámara y el micrófono son los dispositivos predeterminados de macOS; selecciona tu micrófono en Ajustes del Sistema antes de empezar. La cámara aparece espejada en una esquina o llenando el video en Solo cámara. Usa audífonos para evitar que el micrófono capte nuevamente el sonido de los altavoces.

## Calidad y tamaño

- **Resolución nativa fija, a 60 fps**: se conservan los píxeles del modo de pantalla que genera macOS, incluida su escala Retina. Por ejemplo, con el modo actual de este Mac se guardan **2940 × 1912** píxeles. No hay límite de 1080p ni selector de resolución. Los modos inusuales de dimensiones impares recortan únicamente la última fila o columna para la compatibilidad H.264, sin reescalar. Si el codificador no admite un tamaño, se informa del error; no se reduce silenciosamente la calidad.
- 60 fotogramas por segundo como objetivo de captura y codificación. La cámara también utiliza 60 fps si su hardware lo permite; las cámaras limitadas a 30 fps mantienen su frecuencia dentro del video de 60 fps. La fluidez efectiva depende de las fuentes y de la carga del Mac.
- MP4 con video H.264 y preferencia de codificación por hardware. El bitrate se ajusta al número de píxeles: referencia de 8 Mb/s por 1920 × 1080, unos 21,7 Mb/s para 2940 × 1912. Con ambas fuentes, audio AAC estéreo de 192 kb/s; con una sola fuente, se conserva su AAC original (micrófono mono de 96 kb/s o audio del Mac estéreo de 128 kb/s).
- Tamaño orientativo con el modo actual 2940 × 1912: aproximadamente 164 MB por minuto incluyendo audio. El tamaño real depende del contenido y puede ser menor. Ajustes muestra la estimación de la pantalla seleccionada; la resolución nativa requiere más espacio que 1080p.
- Micrófono y audio del sistema se mezclan en **una pista**, para que se escuchen juntos en los reproductores habituales.
- Al terminar, se copia el video comprimido sin volver a codificarlo. Se mezcla el audio cuando hay dos fuentes; una sola pista AAC se copia sin recomprimir. Durante ese proceso se necesita espacio para el archivo temporal y el MP4 final.

La aplicación no sube archivos, no transmite en vivo y no funciona como cámara virtual. No reemplaza la grabación directa exigida por una plataforma de entrevistas. No tiene marcas de agua, cuentas ni servicios externos. La propia ventana de Foco se excluye de la pantalla grabada.

## Rendimiento

La composición reutiliza la imagen anterior si las fuentes no cambiaron, manteniendo los 60 fotogramas por segundo del archivo. Cada fotograma se entrega primero al escritor de video. La vista previa comparte después esa misma superficie inmutable con el renderizador nativo de macOS, sin convertirla en una imagen de CPU ni esperar a que la interfaz la muestre. Si la interfaz se retrasa, conserva solo el fotograma más reciente en lugar de acumular trabajo. Esto mantiene la resolución, la frecuencia objetivo y los parámetros de codificación de la grabación.

El visor ajusta su escala al monitor Retina, y la captura, composición y salida identifican explícitamente el espacio sRGB para conservar el color. La pantalla se compone sin reescalarla; solo la cámara se adapta al recuadro. Se mantiene el tamaño relativo de la cámara y el arrastre al aumentar la resolución.

SwiftUI solo recibe cambios de disponibilidad de la vista previa, no una reconstrucción por cada fotograma. Al ocultar o minimizar la ventana se libera el renderizador; el arrastre de la cámara aplica únicamente la posición más reciente sin reconectar dispositivos. Durante la pausa, el temporizador de video deja de activarse; las fuentes permanecen conectadas para reanudar.

Las actualizaciones de imagen y medidores solo afectan sus vistas y conservan el valor más reciente si la interfaz está ocupada. El contador y la búsqueda de grabaciones anteriores no bloquean la interfaz con consultas a la cola de captura o al disco. El editor agrupa las búsquedas rápidas al arrastrar y libera sus recursos al cerrarse. El MP4 final solo aparece una vez terminado el guardado.

Las mediciones sintéticas de esta versión verificaron 120 fotogramas usando dos composiciones cuando las fuentes solo cambiaban dos veces; 1.000 posiciones de arrastre necesitaron dos búsquedas, conservando la última. En cinco pruebas con un video de 30 segundos y una sola pista AAC, la mediana del guardado bajó de 0,236 a 0,040 segundos. Estas mediciones históricas no representan el consumo total de una captura real ni garantizan el mismo ahorro con cámara o mezcla de dos fuentes.

En la prueba sintética de 240 fotogramas, preparar la muestra nativa de vista previa tomó 0,014 ms de media, frente a 1,725 ms para la conversión anterior a `CGImage`. Composición más preparación nativa tomó 2,73 ms de media (p95: 4,35 ms). Estas cifras miden preparación de fotogramas; no equivalen a los fps efectivos del monitor ni al consumo total de la aplicación.

## Errores y recuperación

- Si faltan permisos, sigue el botón **Abrir Ajustes** y habilita Foco en Privacidad y seguridad. No cambies ni muevas la aplicación después de conceder los permisos si no es necesario.
- Si no hay cámara o micrófono, conecta el dispositivo o desactiva esa fuente.
- Si la captura se interrumpe, Foco intenta guardar el material ya grabado.
- Si falla la mezcla final, conserva un archivo `recuperacion.mov`. Puede tener audio en pistas separadas.
- Si falla la escritura, el mensaje muestra la ruta del temporal. No se garantiza recuperar un archivo si se agotó el disco, hubo un apagado o el proceso se cerró forzosamente.
- El contenido protegido por otras aplicaciones puede no ser capturable. Los dispositivos físicos y sus permisos deben comprobarse con una grabación breve en el propio Mac.

## Compilar y verificar

Requiere las Command Line Tools de Apple y un SDK que incluya ScreenCaptureKit de macOS 15 o posterior. No hay dependencias externas.

Clona el proyecto y entra en su carpeta:

```sh
git clone https://github.com/gustavoamarohidalgo1-ctrl/Grabador-y-recortador.git
cd Grabador-y-recortador
```

Genera el icono, compila la aplicación y ejecuta las pruebas:

```sh
swift scripts/make-icon.swift dist
iconutil -c icns dist/AppIcon.iconset -o dist/AppIcon.icns
bash scripts/build.sh
bash scripts/test.sh
bash scripts/test-trim.sh
bash scripts/test-capture-performance.sh
bash scripts/test-editor.sh
bash scripts/test-presentation.sh
bash scripts/test-preview.sh
bash scripts/test-camera-placement.sh
bash scripts/test-native-quality.sh
bash scripts/test-camera-only.sh
```

La aplicación se genera en `dist/Foco.app`. Copia ese archivo a Aplicaciones y ábrelo desde allí. La carpeta `dist/`, los videos y otros resultados de compilación y pruebas quedan fuera del repositorio.

La compilación utiliza firma local ad hoc. Es una aplicación personal, sin notarización ni certificado de distribución de Apple.

Al recompilar, macOS puede considerar que la identidad de la aplicación cambió y pedir de nuevo sus permisos, incluso si el interruptor anterior aparece activado. Instala la versión definitiva en `/Applications/Foco.app` antes de autorizarla.

Las pruebas utilizan exclusivamente medios sintéticos: geometría, composición, cuatro esquinas, espejo de cámara, duración, 120 fotogramas en dos segundos a 60 fps con marcas de tiempo separadas 1/60 s, preservación del H.264 y mezcla de dos tonos verificando ambos en una única pista AAC. También comprueban cero/una fuente de audio y protección contra sobrescritura. No activan cámara, micrófono ni captura de pantalla reales.

La suite de pausa verifica contador congelado, varias pausas, llamadas repetidas, límites de tiempo y parada en pausa. Un escenario con un segundo grabado, cinco segundos pausados y otro segundo grabado produce un único MP4 de dos segundos a 60 fps, con ambas fuentes de audio.

La suite de recorte comprueba cortes entre fotogramas clave, duración, decodificación de los extremos, resolución, 60 fps, conservación de datos comprimidos y audio, cancelación, límites inválidos y protección del original.

Las pruebas de rendimiento comprueban reutilización de superficies sin alterar el video, búsquedas agrupadas, actualizaciones de interfaz acotadas y rechazo de eventos de sesiones terminadas. Para medir el finalizador con una fuente sintética propia de al menos 10 segundos, 1080p60 y una pista AAC, ejecuta `bash scripts/test-finalizer-performance.sh /ruta/a/video-sintetico.mov`.

Las pruebas de vista previa usan motores simulados para verificar cambios rápidos de opciones, liberación antes de grabar, permisos sin solicitudes automáticas, recuperación de errores y rechazo de imágenes de sesiones anteriores. No acceden a dispositivos reales.

Las pruebas de presentación comprueban que las muestras nativas conservan la misma superficie de píxeles, que los fotogramas nuevos no reconstruyen SwiftUI y que la entrega permanece acotada. Las pruebas de posición verifican el arrastre con bandas laterales/superiores, los límites del encuadre, la posición real de los píxeles y la conservación de fotogramas anteriores. Mil cambios de posición no crean nuevos motores de captura.

## Estructura

- `Sources/Foco/RecorderModel.swift`: estado, permisos y acciones de la aplicación.
- `Sources/Foco/ContentView.swift`: interfaz SwiftUI.
- `Sources/Foco/CapturePresentation.swift` y `PreviewVisibilityObserver.swift`: entrega acotada de imágenes y control de la vista previa visible.
- `Sources/Foco/NativePreviewView.swift`: presentación nativa de las superficies del video, sin conversión a imágenes y con control de saturación.
- `Sources/Foco/CaptureEngine.swift`: ScreenCaptureKit, AVCaptureSession y escritura del video.
- `Sources/Foco/PreviewEngine.swift` y `LivePreviewController.swift`: vista previa independiente de pantalla y cámara, sin audio ni escritura, con inicio y cierre serializados.
- `Sources/Foco/RecordingTimeline.swift`: sincronización de audio y video excluyendo las pausas.
- `Sources/Foco/FrameCompositor.swift`: composición de pantalla y cámara con Core Image.
- `Sources/Foco/MediaFinalizer.swift`: mezcla de audio y MP4 final.
- `Sources/Foco/VideoEditorModel.swift` y `VideoEditorView.swift`: reproductor, selección de intervalo y exportación.
- `Sources/Foco/VideoTrimmer.swift`: recorte sin recodificación y escritura segura del resultado.
- `Tests/MediaSelfTest.swift`: pruebas sintéticas reproducibles.
- `Tests/PauseSelfTest.swift`: pruebas de pausa, reanudación y continuidad del MP4.
- `Tests/TrimSelfTest.swift`: pruebas de recorte, calidad y conservación del original.

Referencias de implementación: [captura de micrófono con ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/) y [mezcla con AVAssetReaderAudioMixOutput](https://developer.apple.com/documentation/avfoundation/avassetreaderaudiomixoutput).

La prueba `bash scripts/test-native-quality.sh` verifica la resolución del modo de pantalla actual con contenido sintético, detalle de un píxel, color, codificación a 60 fps, presentación sin copia de imagen y conservación del video al finalizar. No captura pantalla, cámara ni micrófono del usuario.

Validación nativa de la versión 2.0 en este Mac: 180 fotogramas a 2940 × 1912 y 60 fps, 3 segundos, detalle alterno de un píxel conservado, gris sRGB sin desviación y H.264 idéntico después de finalizar el MP4. Composición + envío al codificador + preparación de muestra para el visor: media 8,13 ms, p95 10,24 ms; sin esperas del codificador en esta prueba. Excluye la adquisición real de pantalla/cámara/audio y la presentación física del monitor, por lo que no garantiza 60 fps bajo cualquier carga.

La prueba `bash scripts/test-camera-only.sh` comprueba cambio pantalla → cámara completa → pantalla dentro de un archivo a 60 fps, exclusión de píxeles del escritorio, espejo y proporciones, buffers inmutables, etiquetas de color y recorte nativo sin recodificación.
