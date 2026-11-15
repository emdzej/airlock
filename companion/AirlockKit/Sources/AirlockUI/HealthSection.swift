import AirlockKit
import SwiftUI

/// The device's SMART health: a section in `DeviceView`. Read once when the
/// device appears (and again for a different medium), not on the devices
/// poll — every read goes through the USB bridge, and airlockd caches it.
struct HealthSection: View {
    let client: AirlockClient
    let device: Device

    private enum Phase: Equatable {
        case loading
        case loaded(SmartReport)
        /// A format, flash or dump holds the device.
        case busy(String)
        case failed(String)
        /// A daemon from before SMART support.
        case hidden
    }

    @State private var phase = Phase.loading
    @State private var refreshing = false

    /// Changes when a different medium is in the slot.
    private var identity: String { "\(device.name)/\(device.serial)/\(device.sizeBytes)" }

    var body: some View {
        Group {
            if !device.isEmpty, phase != .hidden {
                Section("Health") { content }
            }
        }
        .task(id: identity) {
            guard !device.isEmpty else { return }
            phase = .loading
            await load(refresh: false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading SMART…").foregroundStyle(.secondary)
            }
        case let .busy(op):
            Text("Unavailable while \(op) runs.").foregroundStyle(.secondary)
        case let .failed(message):
            Text(message).foregroundStyle(.secondary)
            refreshButton
        case let .loaded(report):
            loaded(report)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private func loaded(_ r: SmartReport) -> some View {
        if r.hasData {
            VStack(alignment: .leading, spacing: 4) {
                verdict(r.status)
                Text(r.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(r.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            figures(r)
            if !r.attributes.isEmpty {
                NavigationLink {
                    SmartAttributesView(report: r, title: device.title)
                } label: {
                    Text("SMART Attributes")
                }
            }
        } else {
            // Unsupported, asleep or unreadable: a quiet line, not an alarm.
            Text(r.summary).foregroundStyle(.secondary)
        }
        if r.status != .unsupported { refreshButton }
    }

    private func verdict(_ s: SmartReport.Status) -> some View {
        let (title, image, tint): (String, String, Color) = switch s {
        case .passed: ("Healthy", "checkmark.seal.fill", .green)
        case .warning: ("Warning", "exclamationmark.triangle.fill", .orange)
        case .failing: ("Failing", "xmark.octagon.fill", .red)
        default: ("Unknown", "questionmark.circle", .secondary)
        }
        return Label(title, systemImage: image).font(.headline).foregroundStyle(tint)
    }

    @ViewBuilder
    private func figures(_ r: SmartReport) -> some View {
        if let t = r.temperatureC { LabeledContent("Temperature", value: "\(t) °C") }
        if let h = r.powerOnHours { LabeledContent("Power-on time", value: Self.hours(h)) }
        if let n = r.powerCycles { LabeledContent("Power cycles", value: n.formatted()) }
        if let u = r.percentageUsed { LabeledContent("Endurance used", value: "\(u)%") }
        if let s = r.availableSpare { LabeledContent("Spare capacity", value: "\(s)%") }
        if let n = r.reallocatedSectors { counter("Reallocated sectors", n) }
        if let n = r.pendingSectors { counter("Pending sectors", n) }
        if let n = r.uncorrectableSectors { counter("Uncorrectable sectors", n) }
        if let n = r.mediaErrors { counter("Media errors", n) }
        if let n = r.unsafeShutdowns { LabeledContent("Unsafe shutdowns", value: n.formatted()) }
        if let b = r.dataWrittenBytes {
            LabeledContent("Data written", value: ByteCountFormatter.string(fromByteCount: b, countStyle: .decimal))
        }
        if !r.protocol.isEmpty || !r.firmware.isEmpty {
            LabeledContent("Interface", value: [r.protocol, r.firmware.isEmpty ? "" : "firmware \(r.firmware)"]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    /// Error counters: orange once they're off zero.
    private func counter(_ title: String, _ n: Int64) -> some View {
        LabeledContent(title) {
            Text(n.formatted()).foregroundStyle(n > 0 ? .orange : .secondary)
        }
    }

    private var refreshButton: some View {
        Button {
            Task {
                refreshing = true
                defer { refreshing = false }
                await load(refresh: true)
            }
        } label: {
            Label(refreshing ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
        }
        .disabled(refreshing)
    }

    private func load(refresh: Bool) async {
        do {
            phase = .loaded(try await client.smart(device.name, refresh: refresh))
        } catch is CancellationError {
        } catch let e as AirlockError where e.status == 404 {
            phase = .hidden
        } catch let e as AirlockError where e.status == 409 {
            // airlockd's message is "<op> in progress on <disk>".
            phase = .busy(e.message.components(separatedBy: " in progress").first ?? "an operation")
        } catch let e as URLError where e.code == .cancelled {
        } catch is URLError {
            phase = .failed("Can't reach this airlock right now.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// "58,192 h (6.6 years)", "1,312 h (55 days)".
    static func hours(_ h: Int64) -> String {
        let span = h >= 24 * 365
            ? String(format: "%.1f years", Double(h) / (24 * 365.25))
            : "\(h / 24) days"
        return "\(h.formatted()) h (\(span))"
    }
}

/// The raw SMART table: ATA attributes with their normalised values and
/// thresholds, or the NVMe health log.
struct SmartAttributesView: View {
    let report: SmartReport
    let title: String

    var body: some View {
        List {
            Section {
                ForEach(Array(report.attributes.enumerated()), id: \.offset) { _, a in
                    if a.value == nil {
                        LabeledContent(a.name, value: a.raw)
                    } else {
                        ataRow(a)
                    }
                }
            } footer: {
                if report.protocol == "ATA" {
                    Text("Normalised values count down towards the threshold; a pre-fail attribute at or below it predicts failure.")
                }
            }
        }
        .navigationTitle("SMART Attributes")
        .macBackButton()
        .inlineNavigationTitle()
        .airlockBackground()
    }

    private func ataRow(_ a: SmartAttribute) -> some View {
        let tint: Color = a.failed == "now" ? .red : a.failed == "past" ? .orange : .primary
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let id = a.id {
                        Text("\(id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(a.name.replacingOccurrences(of: "_", with: " ")).foregroundStyle(tint)
                    if a.prefailure { Badge(text: "Pre-fail") }
                }
                Text(normalised(a)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(a.raw).font(.callout.monospaced()).foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .textSelection(.enabled)
    }

    private func normalised(_ a: SmartAttribute) -> String {
        var parts = [a.value.map { "Value \($0)" }, a.worst.map { "worst \($0)" },
                     a.threshold.map { "threshold \($0)" }].compactMap { $0 }
        if a.failed == "now" { parts.append("failing now") }
        if a.failed == "past" { parts.append("failed in the past") }
        return parts.joined(separator: " · ")
    }
}
