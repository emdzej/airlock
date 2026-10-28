import AirlockKit
import SwiftUI

/// The host's USB block devices. `/api/events` only covers mounted
/// drives, so this polls `/api/devices` (cheap, LAN-local) while the
/// host's screen is up — that's how an inserted-but-unformatted card or
/// a finished flash shows up.
@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var loadError: String?
    @Published private(set) var loaded = false

    private let client: AirlockClient
    private var poller: Task<Void, Never>?

    init(client: AirlockClient) { self.client = client }

    func device(named name: String) -> Device? { devices.first { $0.name == name } }

    func refresh() async {
        do {
            let d = try await client.devices()
            if d != devices { devices = d }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                // Hold the model only for the request, and stop once it's gone.
                do {
                    guard let model = self else { return }
                    await model.refresh()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }
}

/// Row in the host's Devices section.
struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: device.isEmpty ? "sdcard" : "externaldrive.connected.to.line.below.fill",
                     tint: device.isEmpty ? .secondary : .accentColor, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(device.title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text("/dev/\(device.name)").font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    if device.isEmpty {
                        Badge(text: "No media")
                    } else {
                        Badge(text: device.sizeHuman)
                        let n = device.livePartitions.count
                        if n != 1 { Badge(text: n == 0 ? "Unpartitioned" : "\(n) partitions") }
                    }
                    if device.readOnly { Badge(text: "Locked", systemImage: "lock.fill", tint: .orange) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// One device: identity, partitions and the whole-disk operations.
struct DeviceView: View {
    @ObservedObject var host: HostState
    @ObservedObject var model: DevicesModel
    let name: String

    @State private var sheet: SheetKind?
    @State private var labelTarget: Partition?
    @State private var newLabel = ""
    @State private var failure: String?
    @State private var working: String?

    enum SheetKind: Identifiable {
        case format, flash, dump, fsck(Partition)
        var id: String {
            switch self {
            case .format: "format"
            case .flash: "flash"
            case .dump: "dump"
            case let .fsck(p): "fsck-\(p.name)"
            }
        }
    }

    var body: some View {
        Group {
            if let device = model.device(named: name) {
                content(device)
            } else if model.loaded {
                ContentUnavailableView("Device removed", systemImage: "externaldrive.badge.xmark",
                                       description: Text("/dev/\(name) is no longer attached."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.device(named: name)?.title ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { kind in
            if let device = model.device(named: name) {
                switch kind {
                case .format: FormatSheet(client: host.client, device: device) { Task { await model.refresh() } }
                case .flash: FlashSheet(client: host.client, device: device) { Task { await model.refresh() } }
                case .dump: DumpSheet(client: host.client, device: device)
                case let .fsck(p): FsckSheet(client: host.client, partition: p) { Task { await model.refresh() } }
                }
            }
        }
        .alert("Rename \(labelTarget?.name ?? "")", isPresented: Binding(
            get: { labelTarget != nil }, set: { if !$0 { labelTarget = nil } })) {
            TextField("Label", text: $newLabel)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let p = labelTarget { relabel(p, to: newLabel) } }
        } message: {
            if let p = labelTarget, p.maxLabelLen > 0 {
                Text("Up to \(p.maxLabelLen) characters. The partition is briefly unmounted.")
            }
        }
        .alert("Operation failed", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private func content(_ device: Device) -> some View {
        List {
            Section {
                LabeledContent("Device", value: device.path)
                LabeledContent("Size", value: device.isEmpty ? "No media" : device.sizeHuman)
                if !device.ptType.isEmpty {
                    LabeledContent("Partition table", value: device.ptType == "dos" ? "MBR" : device.ptType.uppercased())
                }
                if !device.serial.isEmpty { LabeledContent("Serial", value: device.serial) }
                if device.readOnly || device.anyPartitionReadOnly {
                    Label("Write-protected", systemImage: "lock.fill").foregroundStyle(.secondary)
                }
            }

            if !device.livePartitions.isEmpty {
                Section("Partitions") {
                    ForEach(device.livePartitions) { p in
                        partitionRow(p, device: device)
                    }
                }
            }

            Section {
                Button("Format…", systemImage: "eraser") { sheet = .format }
                    .disabled(!device.isWritable || working != nil)
                Button("Flash Image…", systemImage: "bolt.horizontal") { sheet = .flash }
                    .disabled(!device.isWritable || working != nil)
                Button("Save Image (Dump)…", systemImage: "square.and.arrow.down") { sheet = .dump }
                    .disabled(device.isEmpty || working != nil)
            } footer: {
                Text("Format and Flash erase everything on the device.")
            }

            Section {
                Button("Eject Device", systemImage: "eject", role: .destructive) { eject(device) }
                    .disabled(working != nil || !host.isReachable)
            }
        }
        .overlay {
            if let working {
                ProgressView(working).padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .refreshable { await model.refresh() }
        .airlockBackground()
    }

    private func partitionRow(_ p: Partition, device: Device) -> some View {
        HStack(spacing: 14) {
            IconTile(systemName: p.fsType.isEmpty ? "square.dashed" : "internaldrive",
                     tint: p.shareName != nil ? .accentColor : .secondary, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(p.label.isEmpty ? p.name : p.label).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text("\(p.name) · \(p.sizeHuman)").font(.caption).foregroundStyle(.secondary)
                    Badge(text: p.fsType.isEmpty ? "unformatted" : p.fsType)
                    if p.shareName != nil { Badge(text: "Shared", tint: .accentColor) }
                }
            }
        }
        .contextMenu { partitionActions(p) }
        .swipeActions { partitionActions(p) }
    }

    @ViewBuilder
    private func partitionActions(_ p: Partition) -> some View {
        if p.canMount {
            Button("Mount", systemImage: "externaldrive.badge.plus") { mount(p) }
        }
        if p.canRelabel {
            Button("Rename", systemImage: "pencil") {
                newLabel = p.label
                labelTarget = p
            }
        }
        if p.canFsck {
            Button("Check Filesystem", systemImage: "stethoscope") { sheet = .fsck(p) }
        }
    }

    private func perform(_ title: String, _ body: @escaping () async throws -> Void) {
        working = title
        Task {
            defer { working = nil }
            do { try await body() } catch { failure = error.localizedDescription }
            await model.refresh()
        }
    }

    private func mount(_ p: Partition) {
        perform("Mounting…") { try await host.client.mountPartition(p.name) }
    }

    private func relabel(_ p: Partition, to label: String) {
        let label = label.trimmingCharacters(in: .whitespaces)
        if p.maxLabelLen > 0, label.count > p.maxLabelLen {
            failure = "Labels on \(p.fsType) are at most \(p.maxLabelLen) characters."
            return
        }
        perform("Renaming…") { try await host.client.setLabel(p.name, to: label) }
    }

    private func eject(_ device: Device) {
        perform("Ejecting…") { try await host.client.ejectDevice(device.name) }
    }
}
