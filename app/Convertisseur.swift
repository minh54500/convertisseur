import AppKit
import SwiftUI
import UniformTypeIdentifiers

let repo = "minh54500/convertisseur"

enum Mode: String, CaseIterable {
    case convert, merge, compress, split

    var title: String {
        switch self {
        case .convert: "Convertir"
        case .merge: "Fusionner"
        case .compress: "Compresser"
        case .split: "Découper"
        }
    }
}

// MARK: - Moteur (appelle convert.py embarqué dans l'app)

@MainActor
final class Converter: ObservableObject {
    static let shared = Converter()

    @Published var running = false
    @Published var progress = 0.0
    @Published var current = ""
    @Published var result: String?
    @Published var errors: [String] = []
    @Published var mode: Mode = .convert
    @Published var mergeList: [URL] = []
    @Published var update: String?
    @Published var updating = false
    private var created: [URL] = []
    private var output: URL?
    private var process: Process?
    private var locked: [URL] = []
    private var lastRun: (urls: [URL], args: [String]) = ([], [])

    private var resources: URL { Bundle.main.resourceURL! }
    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Point d'entrée commun (fenêtre, Dock, « Ouvrir avec ») : dépend de l'onglet actif.
    func receive(_ urls: [URL]) {
        if mode == .merge { mergeList += urls.filter { !mergeList.contains($0) } }
        else if let args = arguments() { run(urls, args: args) }
    }

    func merge() {
        if let args = arguments() { run(mergeList, args: args) }
    }

    func cancel() {
        process?.terminate()
    }

    private func arguments() -> [String]? {
        let d = UserDefaults.standard
        var args: [String]
        switch mode {
        case .convert:
            args = ["--to", d.string(forKey: "format") ?? "webp",
                    "-q", String(d.object(forKey: "quality") as? Int ?? 82),
                    "-w", String(d.object(forKey: "maxWidth") as? Int ?? 1600)]
        case .merge:
            args = ["--merge"]
        case .compress:
            args = ["--compress", d.string(forKey: "compressLevel") ?? "medium"]
        case .split:
            args = ["--split"]
            if d.bool(forKey: "splitExtract") {
                let pages = (d.string(forKey: "splitPages") ?? "").trimmingCharacters(in: .whitespaces)
                if pages.isEmpty {
                    result = "Indique d'abord les pages à extraire (ex. 1-3, 7)"
                    return nil
                }
                args += ["--pages", pages]
            }
        }
        if let out = d.string(forKey: "outDir"), !out.isEmpty { args += ["--out-dir", out] }
        return args
    }

    func run(_ urls: [URL], args: [String], password: String? = nil) {
        guard !running, !urls.isEmpty else { return }
        running = true; progress = 0; current = "Préparation…"
        result = nil; errors = []; created = []; output = nil; locked = []
        lastRun = (urls, args)

        let process = Process()
        process.executableURL = resources.appendingPathComponent("python/bin/python3")
        process.arguments = [resources.appendingPathComponent("convert.py").path, "--json"] + args + urls.map(\.path)
        if let password {  // passé par l'environnement : n'apparaît pas dans la liste des processus
            process.environment = ProcessInfo.processInfo.environment.merging(["CONVERTISSEUR_PASSWORD": password]) { $1 }
        }
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
            case "error" where ev["code"] as? String == "password":
                if let path = ev["path"] as? String { locked.append(URL(fileURLWithPath: path)) }
            case "error", "skip":
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
                if args.contains("--merge") && self.output != nil { self.mergeList = [] }
                if !self.locked.isEmpty {
                    DispatchQueue.main.async { self.askPassword(retry: password != nil) }
                    return
                }
                NSSound(named: "Glass")?.play()
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    private func askPassword(retry: Bool) {
        let files = locked
        let alert = NSAlert()
        alert.messageText = files.count == 1
            ? "« \(files[0].lastPathComponent) » est protégé par un mot de passe"
            : "\(files.count) PDF sont protégés par un mot de passe"
        alert.informativeText = (retry ? "Mot de passe incorrect, réessaie.\n\n" : "")
            + "Le fichier créé ne sera pas protégé."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Mot de passe"
        alert.accessoryView = field
        alert.addButton(withTitle: "Déverrouiller")
        alert.addButton(withTitle: "Ignorer")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        // Une fusion est relancée en entier ; sinon seuls les fichiers verrouillés.
        let isMerge = lastRun.args.contains("--merge")
        run(isMerge ? lastRun.urls : files, args: lastRun.args, password: field.stringValue)
    }

    func reveal() {
        if let output { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        else { NSWorkspace.shared.activateFileViewerSelecting(Array(created.prefix(50))) }
    }

    // MARK: Mises à jour

    func checkForUpdate() {
        Task {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
            request.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if latest.compare(version, options: .numeric) == .orderedDescending { update = latest }
        }
    }

    func installUpdate() {
        updating = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | zsh -s -- --update"]
        p.terminationHandler = { p in
            DispatchQueue.main.async {
                guard p.terminationStatus == 0 else {
                    self.updating = false
                    self.result = "La mise à jour a échoué, réessaie plus tard."
                    return
                }
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                relaunch.arguments = ["-c", "sleep 1; open \"$HOME/Applications/Convertisseur.app\""]
                try? relaunch.run()
                NSApp.terminate(nil)
            }
        }
        do { try p.run() } catch { updating = false }
    }

    // MARK: Actions rapides du Finder (copiées depuis l'app à chaque nouvelle version)

    func installQuickActions() {
        let fm = FileManager.default
        let src = resources.appendingPathComponent("services")
        let dst = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services")
        guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        let missing = items.contains { !fm.fileExists(atPath: dst.appendingPathComponent($0.lastPathComponent).path) }
        guard missing || UserDefaults.standard.string(forKey: "servicesVersion") != version else { return }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for item in items {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: item, to: target)
        }
        UserDefaults.standard.set(version, forKey: "servicesVersion")
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        flush.arguments = ["-flush"]
        try? flush.run()
    }
}

// MARK: - Interface

struct ContentView: View {
    @ObservedObject var converter = Converter.shared
    @AppStorage("format") private var format = "webp"
    @AppStorage("quality") private var quality = 82
    @AppStorage("maxWidth") private var maxWidth = 1600
    @AppStorage("compressLevel") private var compressLevel = "medium"
    @AppStorage("splitExtract") private var splitExtract = false
    @AppStorage("splitPages") private var splitPages = ""
    @AppStorage("outDir") private var outDir = ""
    @State private var hovering = false

    private let widths = [(0, "Taille d'origine"), (2560, "2560 px"), (1920, "1920 px"),
                          (1600, "1600 px — web"), (1200, "1200 px"), (800, "800 px")]

    var body: some View {
        VStack(spacing: 16) {
            if let version = converter.update { updateBanner(version) }

            Picker("", selection: $converter.mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(converter.running)

            dropZone
            if converter.mode == .merge { mergePanel }
            settings
            status
        }
        .padding(22)
        .frame(width: 480)
    }

    private func updateBanner(_ version: String) -> some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text("La version \(version) est disponible")
            Spacer()
            Button(converter.updating ? "Mise à jour…" : "Mettre à jour", action: converter.installUpdate)
                .disabled(converter.updating || converter.running)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Zone de dépôt

    private var dropText: (icon: String, title: String, hint: String) {
        switch converter.mode {
        case .convert: ("arrow.down.doc", "Dépose tes fichiers ou dossiers ici",
                        "PDF, JPG, PNG, HEIC, WebP, TIFF, GIF… ou clique pour choisir")
        case .merge: ("doc.on.doc", "Ajoute des PDF ou des images à assembler", "Tu pourras changer l'ordre ensuite")
        case .compress: ("arrow.down.right.and.arrow.up.left", "Dépose les PDF à alléger",
                         "Les images sont réduites, le texte reste net")
        case .split: ("scissors", "Dépose le PDF à découper",
                      splitExtract ? "Indique d'abord les pages ci-dessous" : "Chaque page deviendra un PDF")
        }
    }

    private var dropZone: some View {
        let text = dropText
        return RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(hovering ? Color.accentColor : .secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(hovering ? Color.accentColor.opacity(0.08) : .secondary.opacity(0.05)))
            .frame(height: converter.mode == .merge ? 110 : 160)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: converter.running ? "hourglass" : text.icon)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(hovering ? Color.accentColor : .secondary)
                    Text(converter.running ? "En cours…" : text.title).font(.headline)
                    Text(text.hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
            .onDrop(of: [.fileURL], isTargeted: $hovering, perform: drop)
            .disabled(converter.running)
    }

    // MARK: Réglages

    private var settings: some View {
        Form {
            switch converter.mode {
            case .convert:
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
            case .compress:
                Picker("Compression", selection: $compressLevel) {
                    Text("Légère").tag("light"); Text("Moyenne").tag("medium"); Text("Forte").tag("strong")
                }
                .pickerStyle(.segmented)
                Text(["light": "Qualité quasi intacte, gain modeste.",
                      "medium": "Bon équilibre : idéal pour envoyer par mail.",
                      "strong": "Fichier le plus léger, images moins nettes."][compressLevel] ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            case .split:
                Picker("Découpage", selection: $splitExtract) {
                    Text("Une page par fichier").tag(false); Text("Extraire des pages").tag(true)
                }
                .pickerStyle(.segmented)
                if splitExtract {
                    TextField("Pages", text: $splitPages, prompt: Text("ex. 1-3, 7, 10-"))
                }
            case .merge:
                EmptyView()
            }
            Picker("Enregistrer", selection: outDirChoice) {
                Text("À côté des originaux").tag("")
                if !outDir.isEmpty { Text(URL(fileURLWithPath: outDir).lastPathComponent).tag(outDir) }
                Divider()
                Text("Choisir un dossier…").tag("choose")
            }
        }
        .disabled(converter.running)
    }

    private var outDirChoice: Binding<String> {
        Binding(get: { outDir }, set: { value in
            guard value == "choose" else { outDir = value; return }
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Choisir"
                if panel.runModal() == .OK, let url = panel.url { outDir = url.path }
            }
        })
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
                Button("Fusionner \(converter.mergeList.isEmpty ? "" : "(\(converter.mergeList.count))")", action: converter.merge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(converter.mergeList.isEmpty)
            }
        }
        .disabled(converter.running)
    }

    // MARK: État

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
            let failed = !converter.errors.isEmpty || result.contains("protégé") || result == "Annulé"
                || ["Erreur", "Impossible", "Indique", "La mise à jour", "Fusion interrompue"].contains { result.hasPrefix($0) }
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
        panel.prompt = converter.mode == .merge ? "Ajouter" : converter.mode.title
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            Converter.shared.installQuickActions()
            Converter.shared.checkForUpdate()
        }
    }
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
