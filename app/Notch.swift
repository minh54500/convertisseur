import AppKit
import SwiftUI

// Zone de dépôt sous l'encoche : apparaît quand on glisse un fichier vers le haut de l'écran.

@MainActor
final class NotchDrop {
    static let shared = NotchDrop()

    static let width: CGFloat = 470
    static let contentHeight: CGFloat = 92

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var dragCountAtMouseDown = 0
    private var busy = false

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notchEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "notchEnabled")
            newValue ? start() : stop()
        }
    }

    func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged]
        // Les moniteurs globaux d'événements souris ne demandent aucune autorisation.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { e in
            MainActor.assumeIsolated { NotchDrop.shared.handle(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: events, handler: { e in
            MainActor.assumeIsolated { NotchDrop.shared.handle(e) }
            return e
        }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide()
    }

    private func handle(_ event: NSEvent) {
        let pasteboard = NSPasteboard(name: .drag)
        if event.type == .leftMouseDown {
            dragCountAtMouseDown = pasteboard.changeCount
            return
        }
        // Un nouveau glisser de fichiers est en cours, et le curseur monte vers l'encoche ?
        guard panel == nil, pasteboard.changeCount != dragCountAtMouseDown,
              pasteboard.types?.contains(.fileURL) == true else { return }
        let screen = Self.notchScreen
        let mouse = NSEvent.mouseLocation
        guard mouse.y > screen.frame.maxY - 160, abs(mouse.x - screen.frame.midX) < 420 else { return }
        show(on: screen)
    }

    private static var notchScreen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func show(on screen: NSScreen) {
        let notch = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let size = NSSize(width: Self.width, height: notch + Self.contentHeight)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: NotchView(topInset: notch) { [weak self] urls, mode, format in
            self?.drop(urls, mode: mode, format: format)
        })
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        // Se referme dès que le bouton de la souris est relâché (sauf pendant un traitement).
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let shared = NotchDrop.shared
                if !shared.busy && NSEvent.pressedMouseButtons & 1 == 0 { shared.hide() }
            }
        }
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                            completionHandler: { panel.orderOut(nil) })
    }

    private func drop(_ urls: [URL], mode: Mode, format: String?) {
        busy = true
        Converter.shared.quick(urls, mode: mode, format: format) {
            // Laisse le résultat affiché quelques secondes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotchDrop.shared.busy = false
            }
        }
    }
}

struct NotchView: View {
    let topInset: CGFloat
    let onDrop: ([URL], Mode, String?) -> Void
    @ObservedObject private var converter = Converter.shared
    @State private var dropped = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: topInset)
            Group {
                if dropped {
                    status
                } else {
                    HStack(spacing: 8) {
                        target("WebP", "photo", .convert, "webp")
                        target("JPG", "photo.on.rectangle", .convert, "jpg")
                        target("Fusionner", "doc.on.doc", .merge, nil)
                        target("Compresser", "arrow.down.right.and.arrow.up.left", .compress, nil)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .frame(width: NotchDrop.width)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26).fill(.black))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var status: some View {
        if converter.running {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: converter.progress).tint(.white)
                Text(converter.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } else {
            Label(converter.result ?? "", systemImage: converter.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(converter.errors.isEmpty ? .green : .orange)
                .font(.callout)
                .lineLimit(2)
        }
    }

    private func target(_ title: String, _ icon: String, _ mode: Mode, _ format: String?) -> some View {
        DropTarget(title: title, icon: icon) { urls in
            dropped = true
            onDrop(urls, mode, format)
        }
    }
}

private struct DropTarget: View {
    let title: String
    let icon: String
    let action: ([URL]) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20))
            Text(title).font(.caption.weight(.medium))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: 66)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(hovering ? 0.28 : 0.09)))
        .scaleEffect(hovering ? 1.05 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            let group = DispatchGroup()
            var urls = [URL?](repeating: nil, count: providers.count)
            let lock = NSLock()
            for (i, p) in providers.enumerated() {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    lock.lock(); urls[i] = url; lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { action(urls.compactMap { $0 }) }
            return true
        }
    }
}
