import SwiftUI

/// Shown while no airlock has been found: a searching hatch, and what
/// to check — set one up, same network, permission, try the browser.
struct OnboardingView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                RadarHatch()
                    .frame(width: 200, height: 200)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    Text("Looking for airlocks…")
                        .font(.title2.weight(.bold))
                    Text("Airlock finds devices on your local network by itself. Nothing yet? Here's what to check.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    Step(number: 1, systemImage: "cpu",
                         title: "Set up Airlock on a Raspberry Pi",
                         detail: "Flash the Airlock image onto a microSD card for a Raspberry Pi 4, or install it on Raspberry Pi OS.") {
                        Link(destination: Links.install) {
                            Label("Installation guide", systemImage: "arrow.up.right.square")
                        }
                    }
                    Step(number: 2, systemImage: "wifi",
                         title: "Join the same network",
                         detail: "This device and the Pi need to be on the same Wi-Fi or LAN. Guest and corporate networks often block discovery.")
                    #if os(iOS)
                    Step(number: 3, systemImage: "network",
                         title: "Allow Local Network access",
                         detail: "If you tapped Don't Allow, turn Airlock on in Settings › Privacy & Security › Local Network.") {
                        Link(destination: URL(string: "app-settings:")!) {
                            Label("Open Settings", systemImage: "gear")
                        }
                    }
                    #endif
                    Step(number: lastStep, systemImage: "safari",
                         title: "Try the web UI",
                         detail: "If http://airlock.local opens in a browser, the Pi is up and discovery is what's blocked.") {
                        Link(destination: URL(string: "http://airlock.local")!) {
                            Label("Open airlock.local", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                .frame(maxWidth: 520)

                Link(destination: Links.guide) {
                    Label("Read the user guide", systemImage: "book")
                        .font(.callout.weight(.medium))
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity)
        }
        .airlockBackground()
    }

    private var lastStep: Int {
        #if os(iOS)
        4
        #else
        3
        #endif
    }
}

/// One numbered thing to check, with an optional action.
private struct Step<Action: View>: View {
    let number: Int
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .topTrailing) {
                IconTile(systemName: systemImage, size: 44)
                Text("\(number)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.brand, in: .circle)
                    .offset(x: 6, y: -6)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

extension Step where Action == EmptyView {
    init(number: Int, systemImage: String, title: String, detail: String) {
        self.init(number: number, systemImage: systemImage, title: title, detail: detail) { EmptyView() }
    }
}

/// The hatch with rings rippling out from it, like a sonar ping, and a
/// slowly turning wheel: "searching".
struct RadarHatch: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3) { i in
                    let phase = reduceMotion ? 0.5 : ((t / 2.4) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(Color.brand, lineWidth: 2)
                        .scaleEffect(0.45 + phase * 0.6)
                        .opacity((1 - phase) * 0.5)
                }
                Circle()
                    .fill(Color.brand.opacity(0.10))
                    .frame(width: 112, height: 112)
                HatchView(wheelAngle: .degrees(reduceMotion ? 0 : t * 30))
                    .foregroundStyle(Color.brand)
                    .frame(width: 92, height: 92)
            }
        }
        .accessibilityLabel("Searching for airlocks")
    }
}

/// Sidebar placeholder on wide layouts, where the steps fill the detail.
struct SearchingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Searching…").foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
