import AirlockKit
import SwiftUI

/// One airlock: a header card, its shared drives (live from
/// /api/events) and its USB devices.
struct HostView: View {
    @ObservedObject var host: HostState
    @StateObject private var devices: DevicesModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy: Set<String> = []
    @State private var failure: String?
    @State private var confirmEjectAll = false
    @State private var showAbout = false

    /// Asks the owner to confirm and forget this airlock.
    var forget: (() -> Void)?

    init(host: HostState, forget: (() -> Void)? = nil) {
        self.host = host
        self.forget = forget
        _devices = StateObject(wrappedValue: DevicesModel(client: host.client))
    }

    var body: some View {
        List {
            Section {
                HostHeader(host: host, devices: devices.devices)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Drives") {
                if host.drives.isEmpty {
                    EmptyRow(systemImage: "externaldrive.badge.plus",
                             text: host.isReachable ? "Plug in a USB drive or card" : "No drives seen yet")
                }
                ForEach(host.drives) { drive in
                    NavigationLink {
                        FileBrowserView(client: host.client, drive: drive)
                    } label: {
                        DriveCard(drive: drive, busy: busy.contains(drive.id),
                                  canEject: host.isReachable) { eject(drive) }
                    }
                    .swipeActions {
                        Button("Eject", systemImage: "eject") { eject(drive) }
                            .tint(.orange)
                    }
                    .contextMenu {
                        Button("Eject", systemImage: "eject") { eject(drive) }
                        Button("Copy SMB URL", systemImage: "doc.on.doc") {
                            Pasteboard.copy(smbURL(drive))
                        }
                    }
                    .disabled(!host.isReachable || drive.ejecting)
                }
            }

            Section("Devices") {
                if let err = devices.loadError, devices.devices.isEmpty {
                    EmptyRow(systemImage: "exclamationmark.triangle", text: err)
                } else if devices.loaded, devices.devices.isEmpty {
                    EmptyRow(systemImage: "cable.connector", text: "No USB devices attached")
                }
                ForEach(devices.devices) { device in
                    NavigationLink {
                        DeviceView(host: host, model: devices, name: device.name)
                    } label: {
                        DeviceRow(device: device)
                    }
                }
            }
        }
        .airlockBackground()
        .macTransparentToolbar()
        .animation(.default, value: host.drives)
        .animation(.default, value: devices.devices)
        .refreshable { await devices.refresh() }
        .onAppear { if scenePhase.isForeground { devices.startPolling() } }
        .onChange(of: scenePhase) { _, phase in
            if phase.isForeground { devices.startPolling() } else { devices.stopPolling() }
        }
        // A drive appearing or going usually means a device changed too.
        .onChange(of: host.drives) { _, _ in Task { await devices.refresh() } }
        .navigationTitle(host.serviceName)
        .inlineNavigationTitle()
        .toolbar {
            // The header card shows the name; the title stays for the
            // back button on pushed screens.
            #if os(iOS)
            ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
            #endif
            ToolbarItem(placement: .trailingAction) {
                Menu {
                    Button("Eject All", systemImage: "eject") { confirmEjectAll = true }
                        .disabled(!host.isReachable || host.drives.isEmpty)
                    Link(destination: host.baseURL) {
                        Label("Open Web UI", systemImage: "safari")
                    }
                    Divider()
                    Link(destination: Links.guide) {
                        Label("User Guide", systemImage: "book")
                    }
                    Button("About Airlock", systemImage: "info.circle") { showAbout = true }
                    if let forget {
                        Divider()
                        Button("Forget This Airlock", systemImage: "trash", role: .destructive, action: forget)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAbout) { AboutView().sheetFrame(width: 440) }
        .confirmationDialog("Eject every drive on \(host.serviceName)?",
                            isPresented: $confirmEjectAll, titleVisibility: .visible) {
            Button("Eject All", role: .destructive, action: ejectAll)
        }
        .alert("Couldn't eject", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .sensoryFeedback(.error, trigger: failure) { _, new in new != nil }
    }

    private func smbURL(_ drive: Drive) -> String {
        let share = drive.shareName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? drive.shareName
        return "smb://\(host.hostname)/\(share)"
    }

    private func eject(_ drive: Drive) {
        busy.insert(drive.id)
        Task {
            defer { busy.remove(drive.id) }
            do { try await host.client.ejectDrive(drive.shareName) }
            catch { failure = error.localizedDescription }
        }
    }

    private func ejectAll() {
        let ids = Set(host.drives.map(\.id))
        busy.formUnion(ids)
        Task {
            defer { busy.subtract(ids) }
            do { try await host.client.ejectAll() }
            catch { failure = error.localizedDescription }
        }
    }
}

/// The airlock at a glance: hatch, name, live status, counts.
private struct HostHeader: View {
    @ObservedObject var host: HostState
    let devices: [Device]

    var body: some View {
        HStack(spacing: 16) {
            HatchView()
                .foregroundStyle(Color.brand)
                .frame(width: 64, height: 64)
                .padding(10)
                .background(Color.brand.opacity(0.12), in: .rect(cornerRadius: 20, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(host.serviceName)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(host.isReachable ? Color.green : Color.secondary)
                        .symbolEffect(.pulse, options: .repeating, isActive: host.isReachable)
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Text(host.hostname)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 22, style: .continuous))
        .animation(.default, value: status)
    }

    private var status: String {
        guard host.isReachable else {
            if let seen = host.lastSeenOnline, seen > .distantPast {
                return "Offline · seen \(seen.formatted(.relative(presentation: .named)))"
            }
            return host.lastError ?? "Connecting…"
        }
        let d = host.drives.count
        let empty = devices.filter(\.isEmpty).count
        var parts = [d == 1 ? "1 drive" : "\(d) drives"]
        if empty > 0 { parts.append(empty == 1 ? "1 empty slot" : "\(empty) empty slots") }
        return parts.joined(separator: " · ")
    }
}

/// A shared drive: tinted icon, label, size, filesystem badge and an
/// inline eject button.
private struct DriveCard: View {
    let drive: Drive
    let busy: Bool
    let canEject: Bool
    let eject: () -> Void
    @State private var taps = 0

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: icon, tint: drive.readOnly ? .orange : .brand, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(drive.displayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(drive.sizeHuman).font(.subheadline).foregroundStyle(.secondary)
                    Badge(text: fsName)
                    if drive.readOnly { Badge(text: "Read-only", systemImage: "lock.fill", tint: .orange) }
                }
            }
            Spacer(minLength: 0)
            if busy || drive.ejecting {
                ProgressView()
            } else {
                Button {
                    taps += 1
                    eject()
                } label: {
                    Image(systemName: "eject.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.bounce, value: taps)
                }
                .buttonStyle(.borderless)
                .disabled(!canEject)
                .accessibilityLabel("Eject \(drive.displayName)")
            }
        }
        .padding(.vertical, 4)
    }

    /// Kernel names tell SD/MMC slots apart from USB storage.
    private var icon: String {
        drive.kernel.hasPrefix("mmcblk") ? "sdcard.fill" : "externaldrive.fill"
    }

    private var fsName: String {
        switch drive.fsType {
        case "vfat": "FAT32"
        case "exfat": "exFAT"
        case "ntfs": "NTFS"
        default: drive.fsType
        }
    }
}

/// Placeholder row with a symbol, for empty sections.
struct EmptyRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: systemImage, tint: .secondary, size: 44)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
