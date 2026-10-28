import AirlockKit
import SwiftUI

/// Long-running operations in progress anywhere in the app (format,
/// flash, fsck, dump). The background hatch turns while this is > 0.
@MainActor
final class Activity: ObservableObject {
    static let shared = Activity()
    @Published private(set) var running = 0

    func begin() { running += 1 }
    func end() { running = max(0, running - 1) }
}

/// The airlock hatch from the app icon, as line art: a rim with four
/// bolts, and a handwheel (ring, X spokes, hub) that can turn.
public struct HatchView: View {
    var wheelAngle: Angle = .zero
    var lineWidth: CGFloat = 0.035 // fraction of the size

    public init(wheelAngle: Angle = .zero, lineWidth: CGFloat = 0.035) {
        self.wheelAngle = wheelAngle
        self.lineWidth = lineWidth
    }

    public var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let lw = s * lineWidth
            ZStack {
                Circle().inset(by: lw * 1.5).stroke(lineWidth: lw * 1.6)
                Circle().inset(by: lw * 3.4).stroke(lineWidth: lw * 0.6)
                ForEach(0..<4) { i in
                    Circle()
                        .frame(width: lw * 2.4, height: lw * 2.4)
                        .offset(y: -(s / 2 - lw * 1.5))
                        .rotationEffect(.degrees(Double(i) * 90))
                }
                Wheel(lineWidth: lw)
                    .frame(width: s * 0.5, height: s * 0.5)
                    .rotationEffect(wheelAngle)
            }
            .frame(width: s, height: s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private struct Wheel: View {
        let lineWidth: CGFloat

        var body: some View {
            GeometryReader { geo in
                let s = geo.size.width
                ZStack {
                    Circle().inset(by: lineWidth / 2).stroke(lineWidth: lineWidth)
                    ForEach(0..<2) { i in
                        Capsule()
                            .frame(width: lineWidth * 0.8, height: s * 0.96)
                            .rotationEffect(.degrees(45 + Double(i) * 90))
                    }
                    Circle().frame(width: s * 0.26, height: s * 0.26)
                    Circle()
                        .frame(width: s * 0.1, height: s * 0.1)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
        }
    }
}

/// App-wide background: a faint mint wash at the top over the grouped
/// background, and a large hatch watermark off the bottom corner.
struct AirlockBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.groupedBackground
            LinearGradient(colors: [Color.brand.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                           startPoint: .top, endPoint: .center)
            GeometryReader { geo in
                let side = max(geo.size.width, geo.size.height) * 0.85
                WatermarkHatch()
                    .frame(width: side, height: side)
                    .foregroundStyle(Color.brand)
                    .opacity(scheme == .dark ? 0.07 : 0.05)
                    .position(x: geo.size.width * 0.92, y: geo.size.height * 0.88)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Watermark: turns while work runs, then eases into the next locked
/// quarter turn.
private struct WatermarkHatch: View {
    @ObservedObject private var activity = Activity.shared
    @State private var angle: Angle = .zero
    @State private var spinStart: Date?
    @State private var base: Angle = .zero
    private let speed = 24.0 // degrees per second

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: spinStart == nil)) { ctx in
            HatchView(wheelAngle: current(at: ctx.date), lineWidth: 0.02)
        }
        .onChange(of: activity.running > 0, initial: true) { _, busy in
            if busy {
                base = angle
                spinStart = Date()
            } else if let start = spinStart {
                let reached = base.degrees + Date().timeIntervalSince(start) * speed
                spinStart = nil
                angle = .degrees(reached)
                withAnimation(.spring(duration: 0.9, bounce: 0.35)) {
                    angle = .degrees((reached / 90).rounded(.up) * 90)
                }
            }
        }
    }

    private func current(at date: Date) -> Angle {
        guard let start = spinStart else { return angle }
        return .degrees(base.degrees + date.timeIntervalSince(start) * speed)
    }
}

extension View {
    /// Lists and forms over the app background.
    func airlockBackground() -> some View {
        scrollContentBackground(.hidden)
            .background { AirlockBackground() }
    }

    /// Sidebar beside a watermarked detail pane: deep green, drawn in
    /// dark-mode colours so text and icons read on it, and no hatch (it
    /// would be drawn twice side by side).
    func sidebarBackground() -> some View {
        scrollContentBackground(.hidden)
            .background { SidebarTint().ignoresSafeArea() }
            .environment(\.colorScheme, .dark)
    }
}

/// The icon's rim green, darkening towards the bottom.
struct SidebarTint: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.13, green: 0.36, blue: 0.27),
                                Color(red: 0.08, green: 0.25, blue: 0.19)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A rounded, tinted square behind a symbol, like Settings' icons.
struct IconTile: View {
    let systemName: String
    var tint: Color = .brand
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: .rect(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// Small capsule label: filesystem, "Shared", "Read-only".
struct Badge: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(BadgeLabelStyle(hasIcon: systemImage != nil))
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: .capsule)
    }

    private struct BadgeLabelStyle: LabelStyle {
        let hasIcon: Bool
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) {
                if hasIcon { configuration.icon }
                configuration.title
            }
        }
    }
}
