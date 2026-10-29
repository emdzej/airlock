import AirlockKit
import SwiftUI

/// Sidebar on iPad, root list on iPhone: every airlock seen on this
/// network, live ones first.
public struct HostListView: View {
    @ObservedObject var discovery: Discovery
    @State private var selection: String?
    @State private var showAbout = false
    @State private var forgetting: HostState?
    /// The real appearance: the sidebar forces dark colours on itself,
    /// and sheets opened from it shouldn't inherit that.
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init(discovery: Discovery) {
        self.discovery = discovery
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: listSelection) {
                Section {
                    if discovery.hosts.isEmpty, !compact {
                        SearchingRow()
                    }
                    ForEach(discovery.hosts) { host in
                        hostRow(host)
                            .contextMenu {
                                Button("Forget This Airlock", systemImage: "trash", role: .destructive) {
                                    requestForget(host)
                                }
                            }
                            .swipeActions {
                                Button("Forget", systemImage: "trash", role: .destructive) { requestForget(host) }
                            }
                    }
                }
            }
            .navigationTitle("Airlock")
            .safeAreaInset(edge: .bottom) { SidebarFooter(compact: compact) { showAbout = true } }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .modifier(SidebarStyle(compact: compact))
            .sheet(isPresented: $showAbout) {
                AboutView().sheetFrame(width: 440).environment(\.colorScheme, colorScheme)
            }
            .overlay {
                if discovery.hosts.isEmpty, compact {
                    OnboardingView(startDemo: startDemo)
                }
            }
        } detail: {
            if let host = discovery.hosts.first(where: { $0.id == selection }) {
                NavigationStack {
                    HostView(host: host) { requestForget(host) }
                }
                .id(host.id)
            } else if discovery.hosts.isEmpty {
                OnboardingView(startDemo: startDemo)
            } else {
                ContentUnavailableView("Select an airlock", systemImage: "externaldrive.connected.to.line.below")
                    .airlockBackground()
            }
        }
        .tint(.brand)
        .confirmationDialog("Forget \(forgetting?.serviceName ?? "")?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let host = forgetting {
                    if selection == host.id { selection = nil }
                    discovery.forget(host)
                }
            }
        } message: {
            Text("It's removed from this list. If it's still on the network, it shows up again the next time Airlock finds it.")
        }
        .onAppear(perform: selectOnlyHost)
        .onChange(of: discovery.hosts.count) { _, _ in selectOnlyHost() }
    }

    /// iOS: the system selection (on iPhone it's what pushes the host's
    /// screen). macOS: the sidebar's own selection highlight is grey or
    /// the system accent, whatever the background, so the rows are
    /// buttons and draw a green one themselves.
    private var listSelection: Binding<String?> {
        #if os(iOS)
        $selection
        #else
        .constant(nil)
        #endif
    }

    @ViewBuilder
    private func hostRow(_ host: HostState) -> some View {
        #if os(iOS)
        HostRow(host: host).tag(host.id)
        #else
        Button { selection = host.id } label: {
            HostRow(host: host)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selection == host.id ? Color.brand.opacity(0.55) : .clear)
                .padding(.horizontal, 10)
        )
        #endif
    }

    /// iPhone (and iPad split screen): one column, so the onboarding
    /// fills the list; wider layouts show it in the detail pane.
    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// With a single airlock (the usual case) on a regular-width layout,
    /// open it straight away instead of showing an empty detail pane.
    /// Real airlocks ask first; the demo just ends.
    private func requestForget(_ host: HostState) {
        guard host.isDemo else { return forgetting = host }
        if selection == host.id { selection = nil }
        discovery.forget(host)
    }

    private func startDemo() {
        discovery.startDemo()
        selection = DemoAirlock.serviceName
    }

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
                .foregroundStyle(host.isReachable ? Color.brand : Color.secondary)
                .frame(width: 30, height: 30)
                .padding(6)
                .background((host.isReachable ? Color.brand : Color.secondary).opacity(0.12),
                            in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.serviceName).font(.headline)
                    if host.isDemo { Badge(text: "Demo", tint: .brand) }
                }
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

/// One column (iPhone): the list is the whole screen, so it gets the
/// watermark. Beside a detail pane: the plain tint.
private struct SidebarStyle: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        // On the green, the selected row's text (drawn in the tint) has to
        // be light, not the brand green.
        if compact { content.airlockBackground() } else { content.sidebarBackground().tint(.white) }
    }
}

/// Guide and About, kept small at the bottom of the sidebar.
private struct SidebarFooter: View {
    let compact: Bool
    let showAbout: () -> Void

    var body: some View {
        // Labels when they fit on one line, icons when the column is narrow.
        ViewThatFits(in: .horizontal) {
            row.labelStyle(.titleAndIcon)
            row.labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .tint(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // Down to the screen edge, under the home indicator, like a
        // toolbar; not just to the safe-area line.
        .background {
            Group { if compact { Rectangle().fill(.bar) } else { Color.black.opacity(0.18) } }
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) { Divider() }
    }

    private var row: some View {
        HStack(spacing: 16) {
            Link(destination: Links.guide) {
                Label("User Guide", systemImage: "book")
            }
            Spacer(minLength: 0)
            Button(action: showAbout) {
                Label("About · \(AppVersion.marketing)", systemImage: "info.circle")
                    .monospacedDigit()
            }
        }
    }
}
