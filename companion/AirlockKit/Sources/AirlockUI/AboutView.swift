import AirlockKit
import SwiftUI

enum Links {
    static let site = URL(string: "https://airlock.emdzej.pl")!
    static let guide = URL(string: "https://airlock.emdzej.pl/guide")!
    static let install = URL(string: "https://airlock.emdzej.pl/install")!
    static let source = URL(string: "https://github.com/emdzej/airlock")!
    static let changelog = URL(string: "https://github.com/emdzej/airlock/blob/main/CHANGELOG.md")!
    static let license = URL(string: "https://github.com/emdzej/airlock/blob/main/LICENSE")!
}

enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    /// "0.4.1 (7)"
    static var display: String { "\(marketing) (\(build))" }
}

/// App name, version, and where to read more.
public struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hasReports = false
    @State private var confirmErase = false
    @State private var eraseResult: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        HatchView()
                            .foregroundStyle(Color.brand)
                            .frame(width: 84, height: 84)
                            .padding(16)
                            .background(Color.brand.opacity(0.12),
                                        in: .rect(cornerRadius: 28, style: .continuous))
                        Text("Airlock").font(.largeTitle.weight(.bold))
                        Text("Version \(AppVersion.display)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Manage the drives in your airlock from \(Platform.devices): browse files, eject, format, flash and back up images.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section("Learn more") {
                    Link(destination: Links.guide) {
                        Label("User Guide", systemImage: "book")
                    }
                    Link(destination: Links.site) {
                        Label("airlock.emdzej.pl", systemImage: "globe")
                    }
                    Link(destination: Links.changelog) {
                        Label("What's New", systemImage: "sparkles")
                    }
                }

                Section("Open source") {
                    Link(destination: Links.source) {
                        Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: Links.license) {
                        Label("MIT License", systemImage: "doc.text")
                    }
                }

                if Support.isAvailable, hasReports {
                    Section {
                        Button("Erase My Reports…", systemImage: "trash", role: .destructive) { confirmErase = true }
                    } header: {
                        Text("Problem reports")
                    } footer: {
                        Text("Deletes the reports you've sent and their answers at the support desk, and the anonymous id this device sends them with.")
                    }
                }

                Section {
                    LabeledContent("Version", value: AppVersion.marketing)
                    LabeledContent("Build", value: AppVersion.build)
                    LabeledContent(Platform.osName, value: Platform.osVersion)
                } footer: {
                    Text("Airlock talks only to airlock devices on your local network. No accounts, no tracking. A problem report goes to the support desk only when you send one.")
                }
            }
            .airlockBackground()
            .task { hasReports = await Support.hasIdentity() }
            .confirmationDialog("Erase your problem reports?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase", role: .destructive) {
                    Task {
                        do {
                            let n = try await Support.erase()
                            eraseResult = n == 1 ? "1 report erased." : "\(n) reports erased."
                            hasReports = false
                        } catch {
                            eraseResult = error.localizedDescription
                        }
                    }
                }
            } message: {
                Text("They're deleted at the support desk, with support's answers. This can't be undone.")
            }
            .alert(eraseResult ?? "", isPresented: Binding(get: { eraseResult != nil }, set: { if !$0 { eraseResult = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .navigationTitle("About")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
