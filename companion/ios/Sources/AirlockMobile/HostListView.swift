import AirlockKit
import SwiftUI

/// Sidebar on iPad, root list on iPhone: every airlock seen on this
/// network, live ones first.
struct HostListView: View {
    @ObservedObject var discovery: Discovery
    @State private var selection: String?
    @State private var showAbout = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(discovery.hosts) { host in
                        HostRow(host: host).tag(host.id)
                    }
                }
                Section {
                    Link(destination: Links.guide) {
                        Label("User Guide", systemImage: "book")
                    }
                    Button {
                        showAbout = true
                    } label: {
                        LabeledContent {
                            Text(AppVersion.marketing).monospacedDigit()
                        } label: {
                            Label("About Airlock", systemImage: "info.circle")
                        }
                    }
                }
            }
            .navigationTitle("Airlock")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("About", systemImage: "info.circle") { showAbout = true }
                }
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .airlockBackground()
            .overlay {
                if discovery.hosts.isEmpty {
                    ContentUnavailableView(
                        "Looking for airlocks…",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Make sure this device is on the same network as your airlock.")
                    )
                }
            }
        } detail: {
            if let host = discovery.hosts.first(where: { $0.id == selection }) {
                NavigationStack {
                    HostView(host: host)
                }
                .id(host.id)
            } else {
                ContentUnavailableView("Select an airlock", systemImage: "externaldrive.connected.to.line.below")
            }
        }
        .onAppear(perform: selectOnlyHost)
        .onChange(of: discovery.hosts.count) { _, _ in selectOnlyHost() }
    }

    /// With a single airlock (the usual case) on a regular-width layout,
    /// open it straight away instead of showing an empty detail pane.
    private func selectOnlyHost() {
        if selection == nil, discovery.hosts.count == 1 {
            selection = discovery.hosts[0].id
        }
    }
}

private struct HostRow: View {
    @ObservedObject var host: HostState

    var body: some View {
        HStack(spacing: 12) {
            HatchView()
                .foregroundStyle(host.isReachable ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .padding(6)
                .background((host.isReachable ? Color.accentColor : Color.secondary).opacity(0.12),
                            in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.serviceName).font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(host.isReachable ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        if host.isReachable {
            let n = host.drives.count
            return n == 1 ? "1 drive" : "\(n) drives"
        }
        if let seen = host.lastSeenOnline, seen > .distantPast {
            return "offline · last seen \(seen.formatted(.relative(presentation: .named)))"
        }
        return host.lastError ?? "connecting…"
    }
}
