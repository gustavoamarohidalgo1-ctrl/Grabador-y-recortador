import SwiftUI
import AppKit

private let accent = FocoTheme.accent
private let chrome = FocoTheme.chrome
private let canvas = FocoTheme.canvas
private let secondary = FocoTheme.secondary
// Keep the property-wrapper form when building with Command Line Tools, which
// do not bundle the newer SDK's optional SwiftUI macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @ObservedObject var model: RecorderModel
    @ViewState private var showingSettings = false
    @ViewState private var isFullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            previewStage.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note = model.note {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(note).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.note = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Cerrar aviso")
                }.font(.system(size: 11)).foregroundStyle(accent)
                    .padding(.horizontal, 18).padding(.vertical, 9).background(chrome)
            }
            controlBar
        }
        .background(chrome)
        .background(PreviewVisibilityObserver(onChange: model.setPreviewVisible))
        .tint(accent)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            if !model.state.isBusy { model.refreshDisplays() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
        .alert("Foco", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if model.permissionPage != nil { Button("Abrir Ajustes") { model.showPermissions() } }
            Button("Entendido", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "viewfinder").font(.system(size: 17, weight: .medium)).foregroundStyle(accent)
                Text("foco").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.6)
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 17)
            if model.screenEnabled {
              Menu {
                Picker("Pantalla", selection: $model.selectedDisplayID) {
                    ForEach(model.displays) { display in Text(display.name).tag(display.id) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "display")
                    Text(model.selectedDisplay?.name ?? "Seleccionar pantalla").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }.font(.system(size: 11)).foregroundStyle(secondary)
            }.menuStyle(.borderlessButton).fixedSize().disabled(model.state.isBusy)
                .help("Elegir la pantalla que se grabará")
            } else {
                Label("Solo cámara", systemImage: "video")
                    .font(.system(size: 11)).foregroundStyle(secondary)
            }
            Spacer(minLength: 10)
            Text("Nativa · \(RecordingQuality.framesPerSecond) fps").font(.system(size: 10, weight: .medium)).foregroundStyle(secondary)
            iconButton("folder", label: "Abrir grabaciones") { model.openFolder() }
            iconButton("slider.horizontal.3", label: "Ajustes") { showingSettings.toggle() }
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) { settingsPopover }
            iconButton(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       label: isFullScreen ? "Salir de pantalla completa" : "Pantalla completa") {
                let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
                    ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain })
                NSApplication.shared.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                window?.toggleFullScreen(nil)
            }
        }.padding(.horizontal, 18).frame(height: 46).background(chrome)
    }

    private var previewStage: some View {
        GeometryReader { area in
            ZStack {
                canvas
                LiveCaptureImage(presentation: model.presentation, controller: model.livePreview,
                                 model: model, recordingState: model.state, geometry: model.geometry, size: area.size)
                VStack {
                    HStack(spacing: 6) {
                        if model.state == .recording {
                            Circle().fill(accent).frame(width: 6, height: 6)
                            Text("REC").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        } else if model.state == .paused {
                            Image(systemName: "pause.fill").foregroundStyle(accent)
                            Text("EN PAUSA").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                        }
                        Spacer()
                        Text("\(model.geometry.width) × \(model.geometry.height)")
                            .font(.system(size: 10, design: .monospaced))
                    }.foregroundStyle(Color.white.opacity(0.5))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                    Spacer()
                    if let result = model.lastResult, model.state == .ready {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                            Text("Video guardado").font(.system(size: 12, weight: .medium))
                            Text(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))
                                .font(.system(size: 11)).foregroundStyle(secondary)
                            Button("Recortar") { model.openEditor(for: result.url) }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                        }.padding(.horizontal, 16).padding(.vertical, 11)
                            .background(FocoTheme.overlay, in: Capsule()).padding(.bottom, 16)
                    }
                }.allowsHitTesting(model.state == .ready && model.lastResult != nil)
                if model.state == .saving || model.state == .preparing {
                    Color.black.opacity(0.65)
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.regular)
                        Text(model.state == .saving ? "Guardando video…" : "Preparando la captura…")
                            .font(.system(size: 13)).foregroundStyle(secondary)
                    }
                }
                if model.state == .paused {
                    Color.black.opacity(0.22)
                    VStack(spacing: 9) {
                        Label("Grabación en pausa", systemImage: "pause.circle")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
                        Text("Este tramo no se guardará.").font(.system(size: 12)).foregroundStyle(secondary)
                    }.padding(.horizontal, 22).padding(.vertical, 18)
                        .background(FocoTheme.overlay, in: RoundedRectangle(cornerRadius: 14))
                }
            }.frame(width: area.size.width, height: area.size.height).clipped()
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            screenButton
            sourceButton("Cámara", symbol: "video", offSymbol: "video.slash", enabled: $model.cameraEnabled)
            sourceButton("Micrófono", symbol: "mic", offSymbol: "mic.slash", enabled: $model.microphoneEnabled,
                         microphoneMeter: true)
            sourceButton("Audio", symbol: "speaker.wave.2", offSymbol: "speaker.slash", enabled: $model.systemAudioEnabled,
                         microphoneMeter: false)
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle().fill(model.state.isSessionActive ? accent : secondary.opacity(0.35)).frame(width: 6, height: 6)
                Text(model.state == .ready ? "00:00" : model.timeLabel)
                    .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(secondary)
            }.padding(.trailing, 10)
            pauseButton
            recordButton
        }.padding(.horizontal, 18).frame(height: 66).background(chrome)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private var screenButton: some View {
        Button { Task { await model.toggleScreen() } } label: {
            HStack(spacing: 7) {
                Image(systemName: model.screenEnabled ? "display" : "person.crop.rectangle")
                    .font(.system(size: 13)).frame(width: 17)
                Text(model.screenEnabled ? "Pantalla" : "Solo cámara")
                    .font(.system(size: 11, weight: .medium))
            }.padding(.horizontal, 12).frame(height: 34)
                .foregroundStyle(accent)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!model.canSwitchScreen)
            .accessibilityLabel(model.screenEnabled ? "Pantalla" : "Solo cámara")
            .help(model.screenEnabled ? "Desactivar pantalla y usar solo cámara" : "Volver a grabar la pantalla")
    }

    private func sourceButton(_ title: String, symbol: String, offSymbol: String, enabled: Binding<Bool>, microphoneMeter: Bool? = nil) -> some View {
        Button { enabled.wrappedValue.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: enabled.wrappedValue ? symbol : offSymbol)
                    .font(.system(size: 13)).frame(width: 17).foregroundStyle(enabled.wrappedValue ? accent : secondary)
                Text(title).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(enabled.wrappedValue ? Color.white.opacity(0.85) : secondary)
                if let microphoneMeter, enabled.wrappedValue, model.state == .recording {
                    LiveAudioMeter(presentation: model.presentation, microphone: microphoneMeter)
                }
            }.padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(enabled.wrappedValue ? 0.055 : 0.02)))
        }.buttonStyle(.plain).disabled(model.state.isBusy || model.isSwitchingSource || (title == "Cámara" && !model.screenEnabled))
            .help("\(enabled.wrappedValue ? "Desactivar" : "Activar") \(title.lowercased())")
            .accessibilityLabel(title).accessibilityValue(enabled.wrappedValue ? "Activado" : "Desactivado")
    }

    private var pauseButton: some View {
        Button { model.togglePause() } label: {
            Label(model.state == .paused ? "Reanudar" : "Pausar", systemImage: model.state == .paused ? "play.fill" : "pause.fill")
                .font(.system(size: 12, weight: .medium)).frame(width: 108, height: 36)
                .foregroundStyle(model.state == .paused ? accent : Color.white.opacity(0.85))
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(!model.state.isSessionActive)
            .opacity(model.state.isSessionActive ? 1 : 0.3)
            .help("Pausar o reanudar · ⇧⌘P")
    }

    @ViewBuilder private var recordButton: some View {
        if model.state.isSessionActive {
            Button { Task { await model.stopRecording() } } label: {
                Label("Detener", systemImage: "stop.fill").font(.system(size: 12, weight: .semibold))
                    .frame(width: 120, height: 36)
                    .background(accent, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(canvas)
            }.buttonStyle(.plain).help("Detener y guardar · ⇧⌘S")
        } else {
            Button { showingSettings = false; model.beginRecording() } label: {
                HStack(spacing: 8) {
                    if model.state.isBusy { ProgressView().controlSize(.mini) }
                    else { Circle().fill(canvas).frame(width: 8, height: 8) }
                    Text(model.state == .saving ? "Guardando" : model.state.isBusy ? "Preparando" : "Grabar")
                }.font(.system(size: 12, weight: .semibold)).frame(width: 120, height: 36)
                    .background(accent.opacity(model.state.isBusy ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(canvas)
            }.buttonStyle(.plain).disabled(model.state.isBusy || model.isSwitchingSource).help("Iniciar grabación · ⇧⌘R")
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Ajustes").font(.system(size: 15, weight: .semibold))
                Spacer()
                iconButton("xmark", label: "Cerrar ajustes") { showingSettings = false }
            }
            if model.screenEnabled {
              VStack(alignment: .leading, spacing: 9) {
                Text("Posición de la cámara").font(.system(size: 12, weight: .medium))
                Picker("Posición de la cámara", selection: Binding<CameraCorner?>(
                    get: { model.selectedCameraCorner },
                    set: { if let corner = $0 { model.cameraCorner = corner } })) {
                    Text("Personalizada").tag(Optional<CameraCorner>.none)
                    ForEach(CameraCorner.allCases) { corner in Text(corner.title).tag(Optional(corner)) }
                }.labelsHidden().pickerStyle(.menu).disabled(!model.canMoveCamera)
                Text("También puedes arrastrar la cámara sobre la vista previa.")
                    .font(.system(size: 11)).foregroundStyle(secondary)
            }
              Divider()
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Guardar en").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Cambiar") { showingSettings = false; model.chooseOutputDirectory() }
                        .buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 11)).disabled(model.state.isBusy)
                }
                Text(model.outputDirectory.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.system(size: 11)).foregroundStyle(secondary).lineLimit(3).textSelection(.enabled)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("MP4 · Nativa · \(RecordingQuality.framesPerSecond) fps").font(.system(size: 12, weight: .medium))
                Text("\(model.sizeEstimate) · Proporciones originales").font(.system(size: 11)).foregroundStyle(secondary)
                Text("Usa audífonos para evitar que el micrófono vuelva a captar el audio del Mac.")
                    .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            if let file = model.recentFiles.first {
                Divider()
                Button { showingSettings = false; model.openEditor(for: file) } label: {
                    Label("Recortar última grabación", systemImage: "scissors").font(.system(size: 12)).foregroundStyle(accent)
                }.buttonStyle(.plain)
            }
        }.padding(20).frame(width: 310).preferredColorScheme(.dark)
    }
}

private struct LiveCaptureImage: View {
    @ObservedObject var presentation: CapturePresentation
    let controller: LivePreviewController
    @ObservedObject var model: RecorderModel
    let recordingState: RecordingState
    let geometry: RecordingGeometry
    let size: CGSize

    var body: some View {
        ZStack {
            NativePreviewView(presentation: presentation)
                .frame(width: size.width, height: size.height).allowsHitTesting(false)
            if !presentation.hasPreview {
                let ratio = CGFloat(geometry.width) / CGFloat(geometry.height)
                let width = min(max(0, size.width - 32), max(0, size.height - 32) * ratio)
                Rectangle().fill(Color.white.opacity(0.012))
                    .frame(width: width, height: width / ratio)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.05), lineWidth: 1))
            }
            if presentation.hasPreview, model.canMoveCamera {
                CameraDragOverlay(placement: model.cameraPlacement, geometry: geometry,
                                  viewport: size, onMove: model.setCameraPlacement)
            }
            if recordingState == .ready {
                LivePreviewMessage(controller: controller, hasImage: presentation.hasPreview, screenEnabled: model.screenEnabled)
            }
        }
    }
}

private struct CameraDragOverlay: View {
    let placement: CameraPlacement
    let geometry: RecordingGeometry
    let viewport: CGSize
    let onMove: (CameraPlacement) -> Void
    @ViewState private var dragOrigin: CameraPlacement?
    @ViewState private var hovering = false

    var body: some View {
        let rect = placement.previewRect(in: viewport, geometry: geometry)
        ZStack(alignment: .topLeading) {
            Color.clear
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(hovering || dragOrigin != nil ? 0.9 : 0), lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .top) {
                    if hovering || dragOrigin != nil {
                        Label("Arrastra para mover", systemImage: "hand.draw")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.black.opacity(0.75), in: Capsule())
                            .padding(.top, 6).allowsHitTesting(false)
                    }
                }
                .onHover { inside in
                    hovering = inside
                    (inside ? NSCursor.openHand : NSCursor.arrow).set()
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cameraViewport"))
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = placement; NSCursor.closedHand.set() }
                        guard let start = dragOrigin else { return }
                        onMove(start.translated(by: value.translation, in: viewport, geometry: geometry))
                    }
                    .onEnded { value in
                        if let start = dragOrigin {
                            onMove(start.translated(by: value.translation, in: viewport, geometry: geometry))
                        }
                        dragOrigin = nil
                        (hovering ? NSCursor.openHand : NSCursor.arrow).set()
                    })
                .help("Arrastra para cambiar la posición de la cámara")
                .accessibilityLabel("Mover cámara")
                .accessibilityValue("Horizontal \(Int(placement.x * 100))%, vertical \(Int(placement.y * 100))%")
                .position(x: rect.midX, y: rect.midY)
        }
        .frame(width: viewport.width, height: viewport.height)
        .coordinateSpace(name: "cameraViewport")
        .onDisappear { if hovering || dragOrigin != nil { NSCursor.arrow.set() } }
    }
}

private struct LivePreviewMessage: View {
    @ObservedObject var controller: LivePreviewController
    let hasImage: Bool
    let screenEnabled: Bool

    private var needsAction: Bool { controller.state == .needsPermission || controller.state == .failed }

    var body: some View {
        if needsAction || !hasImage {
            VStack(spacing: 12) {
                if controller.state == .starting || controller.state == .live {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: screenEnabled ? "display" : "video").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(secondary)
                }
                Text("Vista previa en vivo").font(.system(size: 15, weight: .medium))
                Text(controller.message ?? (screenEnabled ? "Preparando tu pantalla y cámara…" : "Preparando tu cámara…"))
                    .font(.system(size: 12)).foregroundStyle(secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if needsAction {
                    Button(controller.actionTitle) { Task { await controller.activate() } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(accent, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(canvas)
                }
                Text("No se guarda ningún archivo hasta pulsar Grabar.")
                    .font(.system(size: 11)).foregroundStyle(secondary)
            }.padding(24).frame(maxWidth: 430)
                .background(canvas, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct LiveAudioMeter: View {
    @ObservedObject var presentation: CapturePresentation
    let microphone: Bool

    var body: some View {
        let bars = microphone ? presentation.levels.microphone : presentation.levels.system
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { n in
                Capsule().fill(n < bars ? accent : Color.white.opacity(0.12))
                    .frame(width: 2, height: CGFloat(4 + n * 3))
            }
        }.frame(width: 14, height: 14)
    }
}
