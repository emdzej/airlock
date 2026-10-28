import AirlockKit
import SwiftUI
import UniformTypeIdentifiers

/// Wipe a device and create one partition.
struct FormatSheet: View {
    let client: AirlockClient
    let device: Device
    var onFinish: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = OpRunner()
    @State private var fs: Filesystem = .exfat
    @State private var label = ""
    @State private var confirm = ""

    private var word: String { device.confirmWord(fallback: "FORMAT") }
    private var labelOK: Bool { label.count <= fs.maxLabelLength }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Device", value: "\(device.title) · \(device.sizeHuman)")
                } footer: {
                    Text("Erases every partition on /dev/\(device.name).")
                }
                Section("New filesystem") {
                    Picker("Filesystem", selection: $fs) {
                        ForEach(Filesystem.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Label (optional)", text: $label)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if !labelOK {
                        Text("\(fs.title) labels are at most \(fs.maxLabelLength) characters.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .disabled(runner.phase != .idle)
                if runner.phase == .idle {
                    Section { ConfirmWordField(word: word, text: $confirm) }
                }
                OpProgressSection(runner: runner)
            }
            .navigationTitle("Format")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { sheetToolbar(runner: runner, dismiss: dismiss, action: "Format",
                                    enabled: confirm == word && labelOK, start: start) }
            .interactiveDismissDisabled(runner.isRunning)
            .airlockBackground()
            .sensoryFeedback(trigger: runner.phase) { _, phase in
                switch phase {
                case .running: .warning
                case .done: .success
                case .failed: .error
                default: nil
                }
            }
            .onAppear { if let s = Filesystem(rawValue: device.suggestedFS) { fs = s } }
        }
    }

    private func start() {
        let (client, name, fs, label) = (client, device.name, fs, label)
        runner.start({ client.format(name, fs: fs, label: label) }, onFinish: onFinish)
    }
}

/// Write an image file from Files to the whole device.
struct FlashSheet: View {
    let client: AirlockClient
    let device: Device
    var onFinish: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = OpRunner()
    @State private var picking = false
    @State private var image: URL?
    @State private var imageSize: Int64 = 0
    @State private var compression: Compression = .none
    @State private var confirm = ""
    @State private var pickError: String?

    private var word: String { device.confirmWord(fallback: "FLASH") }
    private var tooBig: Bool { compression == .none && imageSize > device.sizeBytes }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Device", value: "\(device.title) · \(device.sizeHuman)")
                } footer: {
                    Text("Overwrites all of /dev/\(device.name). Raw images (.img, .iso) and xz or gzip compressed ones are supported.")
                }
                Section("Image") {
                    Button {
                        picking = true
                    } label: {
                        if let image {
                            LabeledContent(image.lastPathComponent, value: bytes(imageSize))
                        } else {
                            Label("Choose Image…", systemImage: "doc.badge.plus")
                        }
                    }
                    if image != nil {
                        Picker("Compression", selection: $compression) {
                            ForEach(Compression.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if tooBig {
                        Text("The image is larger than the device.").font(.caption).foregroundStyle(.red)
                    }
                    if let pickError {
                        Text(pickError).font(.caption).foregroundStyle(.red)
                    }
                }
                .disabled(runner.phase != .idle)
                if runner.phase == .idle, image != nil {
                    Section { ConfirmWordField(word: word, text: $confirm) }
                }
                if runner.isRunning {
                    Section {
                        Label("Keep Airlock open until the upload finishes.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                OpProgressSection(runner: runner, expectedBytes: device.sizeBytes)
            }
            .navigationTitle("Flash Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { sheetToolbar(runner: runner, dismiss: dismiss, action: "Flash",
                                    enabled: image != nil && confirm == word && !tooBig, start: start) }
            .interactiveDismissDisabled(runner.isRunning)
            .airlockBackground()
            .sensoryFeedback(trigger: runner.phase) { _, phase in
                switch phase {
                case .running: .warning
                case .done: .success
                case .failed: .error
                default: nil
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .diskImage]) { result in
                switch result {
                case let .success(url): choose(url)
                case let .failure(err): pickError = err.localizedDescription
                }
            }
            .onDisappear { image?.stopAccessingSecurityScopedResource() }
        }
    }

    private func choose(_ url: URL) {
        image?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else {
            pickError = "Couldn't open \(url.lastPathComponent)."
            return
        }
        // Make sure a cloud file is actually on the device before
        // streaming it (coordinated reads download placeholders).
        var coordError: NSError?
        var size: Int64 = 0
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { local in
            size = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        if let coordError {
            pickError = coordError.localizedDescription
            url.stopAccessingSecurityScopedResource()
            return
        }
        pickError = nil
        image = url
        imageSize = size
        compression = Compression(fileName: url.lastPathComponent)
    }

    private func start() {
        guard let image else { return }
        let (client, name, compression) = (client, device.name, compression)
        runner.start({ client.flash(name, image: image, compression: compression) }, onFinish: onFinish)
    }
}

/// Read the whole device into an image file and save it to Files.
struct DumpSheet: View {
    let client: AirlockClient
    let device: Device

    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloader = Downloader()
    @State private var compression: Compression = .xz
    @State private var result: URL?
    @State private var failure: String?
    @State private var exporting = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Device", value: "\(device.title) · \(device.sizeHuman)")
                } footer: {
                    Text("Read-only: the device stays mounted and shared. xz is slowest but makes mostly-empty cards tiny.")
                }
                Section("Compression") {
                    Picker("Compression", selection: $compression) {
                        ForEach(Compression.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .disabled(downloader.isRunning || result != nil)

                if downloader.isRunning || result != nil || failure != nil {
                    Section("Progress") {
                        if let failure {
                            Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        } else if let result {
                            Label("\(result.lastPathComponent) · \(bytes(downloader.received))",
                                  systemImage: "checkmark.circle.fill")
                            Button("Save to Files…", systemImage: "folder") { exporting = true }
                        } else {
                            HStack {
                                ProgressView().padding(.trailing, 4)
                                Text("Reading… \(bytes(downloader.received))").monospacedDigit()
                            }
                            Text("Keep Airlock open until the download finishes.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Save Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(downloader.isRunning ? "Stop" : "Close") {
                        if downloader.isRunning { task?.cancel() } else { cleanUp(); dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result == nil {
                        Button("Start", action: start).disabled(downloader.isRunning)
                    }
                }
            }
            .interactiveDismissDisabled(downloader.isRunning)
            .airlockBackground()
            .sensoryFeedback(.success, trigger: result)
            .sheet(isPresented: $exporting) {
                if let result { DocumentExporter(url: result) { exporting = false } }
            }
        }
    }

    private func start() {
        failure = nil
        let url = client.dumpURL(device.name, compression: compression)
        UIApplication.shared.isIdleTimerDisabled = true
        Activity.shared.begin()
        task = Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                Activity.shared.end()
            }
            do {
                result = try await downloader.download(url)
                exporting = true
            } catch is CancellationError {
                failure = "Stopped"
            } catch let e as URLError where e.code == .cancelled {
                failure = "Stopped"
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func cleanUp() {
        if let result { try? FileManager.default.removeItem(at: result.deletingLastPathComponent()) }
    }
}

/// Check (or repair) a partition's filesystem.
struct FsckSheet: View {
    let client: AirlockClient
    let partition: Partition
    var onFinish: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = OpRunner()
    @State private var repair = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Partition", value: "\(partition.label.isEmpty ? partition.name : partition.label) · \(partition.fsType)")
                    Toggle("Repair errors", isOn: $repair)
                        .disabled(runner.phase != .idle)
                } footer: {
                    Text(repair
                         ? "Fixes what the tool can fix safely. The partition is unmounted while it runs."
                         : "A read-only check. The partition is unmounted while it runs.")
                }
                OpProgressSection(runner: runner)
            }
            .navigationTitle("Check Filesystem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { sheetToolbar(runner: runner, dismiss: dismiss, action: repair ? "Repair" : "Check",
                                    enabled: true, start: start) }
            .interactiveDismissDisabled(runner.isRunning)
            .airlockBackground()
            .sensoryFeedback(trigger: runner.phase) { _, phase in
                switch phase {
                case .running: .warning
                case .done: .success
                case .failed: .error
                default: nil
                }
            }
        }
    }

    private func start() {
        let (client, name, repair) = (client, partition.name, repair)
        runner.start({ client.fsck(name, repair: repair) }, onFinish: onFinish)
    }
}

/// Cancel/Close on the left, the action on the right until it has run.
@ToolbarContentBuilder
@MainActor
func sheetToolbar(runner: OpRunner, dismiss: DismissAction, action: String,
                  enabled: Bool, start: @escaping () -> Void) -> some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
        Button(runner.phase == .idle ? "Cancel" : "Close") { dismiss() }
            .disabled(runner.isRunning)
    }
    ToolbarItem(placement: .confirmationAction) {
        if runner.phase == .idle {
            Button(action, role: .destructive, action: start).disabled(!enabled)
        } else if case .failed = runner.phase {
            Button("Retry", action: start)
        }
    }
}
