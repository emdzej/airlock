import AirlockKit
import QuickLook
import SwiftUI

/// Browse one shared drive: open (Quick Look), save to Files, upload,
/// new folder, rename, delete — the web UI's /drives/{share}/ page.
struct FileBrowserView: View {
    let client: AirlockClient
    let drive: Drive
    /// Directory on the share, "/"-rooted.
    var path: String = "/"

    @State private var entries: [FileEntry] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var loadError: String?

    @State private var importing = false
    @State private var uploadStatus: String?
    @State private var newFolder = false
    @State private var newName = ""
    @State private var renaming: FileEntry?
    @State private var deleting: FileEntry?

    @StateObject private var downloader = Downloader()
    @State private var downloadingName: String?
    @State private var preview: URL?
    @State private var exportURL: URL?

    private var writable: Bool { !drive.readOnly }

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            ForEach(sorted) { entry in
                row(entry)
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if entries.isEmpty, loadError == nil {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .airlockBackground()
        .macTransparentToolbar()
        .navigationTitle(path == "/" ? drive.displayName : (path as NSString).lastPathComponent)
        .inlineNavigationTitle()
        .toolbar {
            if writable {
                ToolbarItem(placement: .trailingAction) {
                    Menu {
                        Button("Upload Files…", systemImage: "square.and.arrow.up") { importing = true }
                        Button("New Folder", systemImage: "folder.badge.plus") {
                            newName = ""
                            newFolder = true
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(uploadStatus != nil)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .airlockRefresh)) { _ in
            Task { await load() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { upload(urls) }
        }
        .quickLookPreview($preview)
        .fileMover(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } }),
                   file: exportURL) { _ in exportURL = nil }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { mkdir(newName) }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let e = renaming { rename(e, to: newName) } }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let e = deleting { remove(e) } }
        } message: {
            if deleting?.isDir == true { Text("The folder and everything in it is deleted.") }
        }
        .alert("Something went wrong", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    /// Folders first, then by name, like Finder.
    private var sorted: [FileEntry] {
        entries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        let content = HStack(spacing: 12) {
            Image(systemName: entry.isDir ? "folder.fill" : icon(for: entry.name))
                .foregroundStyle(entry.isDir ? Color.brand : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(2)
                Text(entry.isDir
                     ? entry.modified.formatted(date: .abbreviated, time: .shortened)
                     : "\(bytes(entry.size)) · \(entry.modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if downloadingName == entry.name { ProgressView() }
        }
        Group {
            if entry.isDir {
                NavigationLink {
                    FileBrowserView(client: client, drive: drive, path: join(entry.name))
                } label: { content }
            } else {
                Button { open(entry) } label: { content }
                    .tint(.primary)
            }
        }
        .contextMenu { actions(entry) }
        .swipeActions { if writable { Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry } } }
    }

    @ViewBuilder
    private func actions(_ entry: FileEntry) -> some View {
        if !entry.isDir {
            Button("Open", systemImage: "eye") { open(entry) }
            Button("Save a Copy…", systemImage: "folder") { save(entry) }
        }
        if writable {
            Button("Rename", systemImage: "pencil") {
                newName = entry.name
                renaming = entry
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = entry }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let status = uploadStatus ?? downloadStatus {
            HStack {
                ProgressView().padding(.trailing, 4)
                Text(status).font(.footnote).monospacedDigit().lineLimit(1)
                Spacer()
            }
            .padding()
            .background(.regularMaterial)
        }
    }

    private var downloadStatus: String? {
        guard let name = downloadingName else { return nil }
        let total = downloader.expected > 0 ? " / \(bytes(downloader.expected))" : ""
        return "Downloading \(name) · \(bytes(downloader.received))\(total)"
    }

    // MARK: - Actions

    private func join(_ name: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }

    private func load() async {
        do {
            entries = try await client.list(drive.shareName, path: path).entries
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func fetch(_ entry: FileEntry) async -> URL? {
        guard downloadingName == nil else { return nil }
        downloadingName = entry.name
        defer { downloadingName = nil }
        do {
            return try await downloader.download(client.downloadURL(drive.shareName, path: join(entry.name)))
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    private func open(_ entry: FileEntry) {
        Task { if let url = await fetch(entry) { preview = url } }
    }

    private func save(_ entry: FileEntry) {
        Task { if let url = await fetch(entry) { exportURL = url } }
    }

    private func upload(_ urls: [URL]) {
        Task {
            for (i, url) in urls.enumerated() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                let prefix = urls.count > 1 ? "(\(i + 1)/\(urls.count)) " : ""
                uploadStatus = "Uploading \(prefix)\(name)…"
                do {
                    try await client.upload(drive.shareName, path: join(name), from: url) { sent, total in
                        Task { @MainActor in
                            uploadStatus = "Uploading \(prefix)\(name) · \(bytes(sent)) / \(bytes(total))"
                        }
                    }
                } catch {
                    failure = "\(name): \(error.localizedDescription)"
                    break
                }
            }
            uploadStatus = nil
            await load()
        }
    }

    private func mutate(_ body: @escaping () async throws -> Void) {
        Task {
            do { try await body() } catch { failure = error.localizedDescription }
            await load()
        }
    }

    private func mkdir(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        mutate { try await client.makeDirectory(drive.shareName, path: join(name)) }
    }

    private func rename(_ entry: FileEntry, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != entry.name else { return }
        mutate { try await client.move(drive.shareName, from: join(entry.name), to: join(name)) }
    }

    private func remove(_ entry: FileEntry) {
        mutate { try await client.remove(drive.shareName, path: join(entry.name)) }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "raw", "cr2", "nef", "arw", "dng": "photo"
        case "mov", "mp4", "m4v", "avi", "mkv": "film"
        case "mp3", "wav", "aac", "m4a", "flac": "waveform"
        case "pdf": "doc.richtext"
        case "zip", "gz", "xz", "7z", "rar", "tar": "doc.zipper"
        case "img", "iso", "dmg": "opticaldiscdrive"
        case "txt", "md", "log", "csv", "json", "xml": "doc.text"
        default: "doc"
        }
    }
}
