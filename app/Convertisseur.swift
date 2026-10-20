import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Moteur (appelle convert.py embarqué dans l'app)

@MainActor
final class Converter: ObservableObject {
    static let shared = Converter()

    @Published var running = false
    @Published var progress = 0.0
    @Published var current = ""
    @Published var result: String?
    @Published var errors: [String] = []
    @Published var mode = "convert"
    @Published var mergeList: [URL] = []
    private var created: [URL] = []
    private var output: URL?
    private var process: Process?

    private var resources: URL { Bundle.main.resourceURL! }

    /// Point d'entrée commun (fenêtre, Dock, « Ouvrir avec ») : dépend de l'onglet actif.
    func receive(_ urls: [URL]) {
        if mode == "merge" { mergeList += urls.filter { !mergeList.contains($0) } }
        else { run(urls) }
    }

    func merge() {
        let list = mergeList
        run(list, merge: true)
    }

    func cancel() {
        process?.terminate()
    }

    func run(_ urls: [URL], merge: Bool = false) {
        guard !running, !urls.isEmpty else { return }
        let d = UserDefaults.standard
        var args = [resources.appendingPathComponent("convert.py").path, "--json"]
        if merge {
            args.append("--merge")
        } else {
            args += ["--to", d.string(forKey: "format") ?? "webp",
                     "-q", String(d.object(forKey: "quality") as? Int ?? 82),
                     "-w", String(d.object(forKey: "maxWidth") as? Int ?? 1600)]
        }

        running = true; progress = 0; current = "Préparation…"
        result = nil; errors = []; created = []; output = nil

        let process = Process()
        process.executableURL = resources.appendingPathComponent("venv/bin/python3")
        process.arguments = args + urls.map(\.path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        self.process = process

        func handle(_ ev: [String: Any]) {
            switch ev["type"] as? String {
            case "done":
                let i = ev["index"] as? Int ?? 0, total = ev["total"] as? Int ?? 1
                progress = Double(i) / Double(max(total, 1))
                current = ev["src"] as? String ?? ""
                if let dst = ev["dst"] as? String { created.append(URL(fileURLWithPath: dst)) }
            case "error":
                errors.append("\(ev["src"] as? String ?? "?") : \(ev["message"] as? String ?? "")")
            case "summary":
                if let out = ev["out"] as? String, !out.isEmpty { output = URL(fileURLWithPath: out) }
                result = ev["message"] as? String
            default: break
            }
        }

        do { try process.run() } catch {
            running = false
            result = "Impossible de lancer le moteur : \(error.localizedDescription)"
            return
        }
        // Lecture ligne par ligne en arrière-plan ; main.async garde l'ordre des événements.
        DispatchQueue.global().async {
            let reader = pipe.fileHandleForReading
            var buffer = Data()
            while case let chunk = reader.availableData, !chunk.isEmpty {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let ev = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { handle(ev) }
                    }
                }
            }
            process.waitUntilExit()
            DispatchQueue.main.async {
                self.running = false
                self.progress = 1
                self.process = nil
                if process.terminationReason == .uncaughtSignal {
                    self.result = "Annulé"
                    return
                }
                if self.result == nil { self.result = "Erreur : le moteur s'est arrêté" }
                if merge && self.output != nil { self.mergeList = [] }
                NSSound(named: "Glass")?.play()
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    func reveal() {
        if let output { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        else { NSWorkspace.shared.activateFileViewerSelecting(Array(created.prefix(50))) }
    }
}

// MARK: - Interface

struct ContentView: View {
    @ObservedObject var converter = Converter.shared
    @AppStorage("format") private var format = "webp"
    @AppStorage("quality") private var quality = 82
    @AppStorage("maxWidth") private var maxWidth = 1600
    @State private var hovering = false

    private let widths = [(0, "Taille d'origine"), (2560, "2560 px"), (1920, "1920 px"),
                          (1600, "1600 px — web"), (1200, "1200 px"), (800, "800 px")]

    var body: some View {
        VStack(spacing: 18) {
            Picker("", selection: $converter.mode) {
                Text("Convertir").tag("convert")
                Text("Fusionner en PDF").tag("merge")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(converter.running)

            dropZone
            if converter.mode == "convert" { settings } else { mergePanel }
            status
        }
        .padding(22)
        .frame(width: 460)
    }

    private var isMerge: Bool { converter.mode == "merge" }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(hovering ? Color.accentColor : .secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(hovering ? Color.accentColor.opacity(0.08) : .secondary.opacity(0.05)))
            .frame(height: isMerge ? 120 : 190)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: converter.running ? "hourglass" : isMerge ? "doc.on.doc" : "arrow.down.doc")
                        .font(.system(size: isMerge ? 30 : 40, weight: .light))
                        .foregroundStyle(hovering ? Color.accentColor : .secondary)
                    Text(converter.running ? "En cours…"
                         : isMerge ? "Ajoute des PDF ou des images à assembler" : "Dépose tes fichiers ou dossiers ici")
                        .font(.headline)
                    Text(isMerge ? "Tu pourras changer l'ordre ensuite"
                         : "PDF, JPG, PNG, HEIC, WebP, TIFF, GIF… ou clique pour choisir")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
            .onDrop(of: [.fileURL], isTargeted: $hovering, perform: drop)
            .disabled(converter.running)
    }

    private var settings: some View {
        Form {
            Picker("Format", selection: $format) {
                Text("WebP").tag("webp"); Text("JPG").tag("jpg")
                Text("PNG").tag("png"); Text("AVIF").tag("avif")
            }
            .pickerStyle(.segmented)
            Picker("Largeur max", selection: $maxWidth) {
                ForEach(widths, id: \.0) { Text($0.1).tag($0.0) }
            }
            if format != "png" {
                LabeledContent("Qualité") {
                    HStack {
                        Slider(value: Binding(get: { Double(quality) }, set: { quality = Int($0) }), in: 40...100, step: 1)
                        Text("\(quality)").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
            }
        }
        .disabled(converter.running)
    }

    private var mergePanel: some View {
        VStack(spacing: 10) {
            if !converter.mergeList.isEmpty {
                List {
                    ForEach(Array(converter.mergeList.enumerated()), id: \.element) { i, url in
                        HStack {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { converter.mergeList.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onMove { converter.mergeList.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: min(CGFloat(converter.mergeList.count) * 28 + 12, 220))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Glisse les lignes pour changer l'ordre").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Vider") { converter.mergeList = [] }
                    .disabled(converter.mergeList.isEmpty)
                Spacer()
                Button("Fusionner \(converter.mergeList.count > 0 ? "(\(converter.mergeList.count))" : "")") {
                    converter.merge()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(converter.mergeList.isEmpty)
            }
        }
        .disabled(converter.running)
    }

    @ViewBuilder private var status: some View {
        if converter.running {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: converter.progress)
                    Text(converter.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Button("Annuler", action: converter.cancel)
            }
        } else if let result = converter.result {
            let failed = !converter.errors.isEmpty || result == "Annulé" || result.hasPrefix("Erreur") || result.hasPrefix("Impossible")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(result, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(failed ? .orange : .green)
                    Spacer()
                    Button("Afficher dans le Finder", action: converter.reveal)
                }
                if !converter.errors.isEmpty {
                    Text(converter.errors.prefix(5).joined(separator: "\n")
                         + (converter.errors.count > 5 ? "\n… et \(converter.errors.count - 5) autre(s)" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = isMerge ? "Ajouter" : "Convertir"
        if panel.runModal() == .OK { converter.receive(panel.urls) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls = [URL?](repeating: nil, count: providers.count)  // garde l'ordre du glisser
        let lock = NSLock()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                lock.lock(); urls[i] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { converter.receive(urls.compactMap { $0 }) }
        return true
    }
}

// MARK: - App (accepte aussi les fichiers déposés sur l'icône du Dock)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Converter.shared.receive(urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ConvertisseurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Convertisseur", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
