import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshDisplayPreview()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        refreshDisplayPreview()
    }

    private func refreshDisplayPreview() {
        let model = RecorderModel.shared
        // An active movie keeps the dimensions with which its encoder started.
        if model.state == .ready { model.refreshDisplays() }
        model.updateIdlePreview()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !RecorderModel.shared.state.isBusy && !RecorderModel.shared.editorIsExporting
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = RecorderModel.shared
        if model.editorIsExporting {
            let alert = NSAlert()
            alert.messageText = "Se está exportando el video"
            alert.informativeText = "Espera a que termine o cancela la exportación desde el editor antes de salir."
            alert.addButton(withTitle: "Volver al editor")
            alert.runModal()
            return .terminateCancel
        }
        if model.state.isSessionActive {
            let alert = NSAlert()
            alert.messageText = model.state == .paused ? "Hay una grabación en pausa" : "Hay una grabación en curso"
            alert.informativeText = "Puedes detenerla y guardar el video antes de salir."
            alert.addButton(withTitle: "Volver a Foco")
            alert.addButton(withTitle: "Guardar y salir")
            if alert.runModal() == .alertSecondButtonReturn {
                Task {
                    await model.stopRecording(showEditor: false)
                    sender.reply(toApplicationShouldTerminate: false)
                    // Stay open if saving failed so the error and recovery instructions remain visible.
                    if model.lastResult != nil { sender.terminate(nil) }
                }
                return .terminateLater
            }
            return .terminateCancel
        }
        if model.state.isBusy { return .terminateCancel }
        Task {
            await model.shutdownPreview()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct FocoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = RecorderModel.shared
    var body: some Scene {
        WindowGroup("Foco") {
            Group {
                if let editor = model.editor {
                    VStack(spacing: 0) {
                        if let notice = model.note {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.circle")
                                Text(notice).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button { model.note = nil } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help("Cerrar aviso")
                            }.font(.system(size: 11)).foregroundStyle(FocoTheme.accent)
                                .padding(12).background(Color.black.opacity(0.8))
                        }
                        VideoEditorView(editor: editor, onClose: { model.closeEditor() })
                    }
                } else {
                    ContentView(model: model)
                }
            }
                .preferredColorScheme(.dark)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1240, height: 850)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir video para recortar…") { model.chooseVideoForEditing() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.state.isBusy || model.editorIsExporting)
            }
            CommandMenu("Grabación") {
                Button("Iniciar grabación") { model.beginRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.state.isBusy || model.editor != nil)
                Button(model.state == .paused ? "Reanudar" : "Pausar") { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.state.isSessionActive)
                Button("Detener y guardar") { Task { await model.stopRecording() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.state.isSessionActive)
                Divider()
                Button("Abrir grabaciones") { model.openFolder() }
            }
        }
    }
}
