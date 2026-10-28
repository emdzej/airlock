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
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                if started {
                    discovery.resume()
                } else {
                    started = true
                    discovery.onChange = { [discovery, filesDomains] in filesDomains.update(discovery.hosts) }
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
