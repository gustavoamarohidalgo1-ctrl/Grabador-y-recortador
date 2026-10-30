import SwiftUI
import AppKit
import AVKit

private let editorAccent = FocoTheme.accent
private let editorChrome = FocoTheme.chrome
private let editorCanvas = FocoTheme.canvas
private let editorSecondary = FocoTheme.secondary

struct VideoEditorView: View {
    @ObservedObject var editor: VideoEditorModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { area in
                ZStack {
                    editorCanvas
                    EditorPlayerView(player: editor.player)
                        .equatable()
                        .frame(width: area.size.width, height: area.size.height)
                    if editor.isLoading {
                        editorCanvas
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Abriendo tu grabación…").font(.system(size: 12)).foregroundStyle(editorSecondary)
                        }
                    }
                    if let result = editor.exportedURL, !editor.isExporting {
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(editorAccent)
                                Text("Recorte exportado").font(.system(size: 12, weight: .medium))
                                Button("Mostrar archivo") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(editorAccent)
                            }.padding(.horizontal, 16).padding(.vertical, 11)
                                .background(FocoTheme.overlay, in: Capsule()).padding(.bottom, 18)
                        }
                    }
                    if editor.isExporting {
                        Color.black.opacity(0.7)
                        VStack(spacing: 14) {
                            Text("Exportando recorte…").font(.system(size: 15, weight: .medium))
                            ProgressView(value: editor.exportProgress).frame(width: 230).tint(editorAccent)
                            Text("\(Int(editor.exportProgress * 100)) %").font(.system(size: 12, design: .monospaced)).foregroundStyle(editorSecondary)
                            Button("Cancelar") { editor.cancelExport() }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(editorSecondary)
                        }
                    }
                }.frame(width: area.size.width, height: area.size.height).clipped()
            }
            trimControls
        }
        .background(editorChrome).tint(editorAccent).preferredColorScheme(.dark)
        .alert("Foco", isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } })) {
            Button("Entendido", role: .cancel) { editor.errorMessage = nil }
        } message: { Text(editor.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button { editor.pausePlayback(); onClose() } label: {
                Label("Volver a grabar", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(editorSecondary)
            }.buttonStyle(.plain).disabled(editor.isExporting)
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 17)
            Text(editor.sourceURL.lastPathComponent).font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(editor.qualityLabel).font(.system(size: 10)).foregroundStyle(editorSecondary).fixedSize()
            Button { editor.chooseExport() } label: {
                Label("Exportar", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 110, height: 34)
                    .background(editorAccent.opacity(editor.canExport ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(editorCanvas)
            }.buttonStyle(.plain).disabled(!editor.canExport)
        }.padding(.horizontal, 18).frame(height: 54)
    }

    private var trimControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("RECORTAR").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(editorSecondary)
                Text("Arrastra los extremos para elegir el fragmento.").font(.system(size: 11)).foregroundStyle(editorSecondary)
                Spacer()
                Text("El original se conserva.").font(.system(size: 10)).foregroundStyle(editorSecondary)
            }
            TrimTimeline(editor: editor)
            HStack(spacing: 12) {
                Button { editor.togglePlayback() } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13)).foregroundStyle(editorAccent)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).help(editor.isPlaying ? "Pausar reproducción" : "Reproducir selección")
                    .accessibilityLabel(editor.isPlaying ? "Pausar reproducción" : "Reproducir selección")
                    .keyboardShortcut(.space, modifiers: [])
                Text(VideoEditorModel.timeLabel(editor.currentTime))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(editorSecondary).frame(width: 94, alignment: .leading)
                Spacer(minLength: 10)
                timeField("Inicio", value: Binding(get: { editor.startTime }, set: { editor.setStart($0) }))
                timeField("Fin", value: Binding(get: { editor.endTime }, set: { editor.setEnd($0) }))
                Text("Duración  \(VideoEditorModel.timeLabel(editor.selectedDuration))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(editorAccent)
                    .padding(.leading, 8)
            }
        }.padding(.horizontal, 20).padding(.vertical, 16)
            .background(editorChrome)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
            .disabled(editor.isLoading || editor.isExporting || editor.duration <= 0)
    }

    private func timeField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 7) {
            Text(label).font(.system(size: 11)).foregroundStyle(editorSecondary)
            TextField("0.000", value: value, format: .number.precision(.fractionLength(3)))
                .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing).frame(width: 70)
                .padding(.horizontal, 9).frame(height: 30)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(label) del recorte en segundos")
            Text("s").font(.system(size: 10)).foregroundStyle(editorSecondary)
        }
    }
}

private struct EditorPlayerView: NSViewRepresentable, Equatable {
    let player: AVPlayer
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.player === rhs.player }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

private struct TrimTimeline: View {
    @ObservedObject var editor: VideoEditorModel
    var body: some View {
        GeometryReader { area in
            let width = max(1, area.size.width - 16)
            let duration = max(0.001, editor.duration)
            let start = 8 + width * min(1, max(0, editor.startTime / duration))
            let end = 8 + width * min(1, max(0, editor.endTime / duration))
            let cursor = 8 + width * min(1, max(0, editor.currentTime / duration))
            ZStack(alignment: .topLeading) {
                ThumbnailStrip(images: editor.thumbnails, width: width)
                    .equatable()
                    .offset(x: 8, y: 5)
                Rectangle().fill(.black.opacity(0.65)).frame(width: max(0, start - 8), height: 50).offset(x: 8, y: 5)
                Rectangle().fill(.black.opacity(0.65)).frame(width: max(0, width + 8 - end), height: 50).offset(x: end, y: 5)
                RoundedRectangle(cornerRadius: 5).stroke(editorAccent, lineWidth: 2)
                    .frame(width: max(1, end - start), height: 52).offset(x: start, y: 4)
                Color.clear.frame(width: width, height: 60).contentShape(Rectangle()).offset(x: 8)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("editorTimeline"))
                        .onChanged { gesture in editor.seek(to: (gesture.location.x - 8) / width * duration) })
                Rectangle().fill(.white).frame(width: 1, height: 58).offset(x: cursor, y: 1).allowsHitTesting(false)
                handle(isStart: true).position(x: start, y: 30)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("editorTimeline"))
                        .onChanged { gesture in editor.setStart((gesture.location.x - 8) / width * duration) })
                handle(isStart: false).position(x: end, y: 30)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("editorTimeline"))
                        .onChanged { gesture in editor.setEnd((gesture.location.x - 8) / width * duration) })
            }.coordinateSpace(name: "editorTimeline")
        }.frame(height: 60)
    }

    private func handle(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(editorAccent).frame(width: 14, height: 60)
            .overlay(Capsule().fill(editorCanvas.opacity(0.55)).frame(width: 2, height: 19))
            .contentShape(Rectangle())
            .accessibilityLabel(isStart ? "Inicio del recorte" : "Fin del recorte")
            .accessibilityValue(VideoEditorModel.timeLabel(isStart ? editor.startTime : editor.endTime))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? editor.frameDuration : -editor.frameDuration
                if isStart { editor.setStart(editor.startTime + step) }
                else { editor.setEnd(editor.endTime + step) }
            }
    }
}

/// Playback updates only move the playhead; the twelve image cells stay unchanged.
private struct ThumbnailStrip: View, Equatable {
    let images: [CGImage]
    let width: CGFloat
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width && lhs.images.elementsEqual(rhs.images, by: { $0 === $1 })
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<12, id: \.self) { index in
                ZStack {
                    Color.white.opacity(index % 2 == 0 ? 0.07 : 0.045)
                    if index < images.count {
                        Image(decorative: images[index], scale: 1).resizable().aspectRatio(contentMode: .fill)
                    }
                }.frame(width: width / 12, height: 50).clipped()
            }
        }.frame(width: width, height: 50).clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
