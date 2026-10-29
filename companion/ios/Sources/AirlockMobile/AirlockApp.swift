import AirlockKit
import AirlockUI
import SwiftUI

@main
struct AirlockApp: App {
    @StateObject private var discovery = Discovery()
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = false
    private let filesDomains = FilesDomains()

    var body: some Scene {
        WindowGroup {
            HostListView(discovery: discovery)
                .onReceive(NotificationCenter.default.publisher(for: .airlockFilesChanged)) { _ in
                    filesDomains.signalChanges()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                if started {
                    discovery.resume()
                    filesDomains.signalChanges()
                } else {
                    started = true
                    discovery.onChange = { [discovery, filesDomains] in filesDomains.update(discovery.networkHosts) }
                    discovery.start()
                }
            case .background:
                discovery.suspend()
            default:
                break
            }
        }
    }
}
