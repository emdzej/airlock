import AirlockKit
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Serves one airlock share (one File Provider domain) to the Files app
/// over airlockd's HTTP file API: ls, dl, upload, mkdir, mv, rm.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let drive: DriveDomainID?
    let client: AirlockClient?
    let items: ItemMap

    /// Whether Files may be holding a "server unreachable" from us: until
    /// it's signalled resolved, Files shows a sync-problem badge and holds
    /// back background work for the domain. Starts true, since a previous
    /// run of the extension may have reported it.
    private let unreachableLock = NSLock()
    private var reportedUnreachable = true

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        drive = DriveDomainID(domain.identifier.rawValue)
        client = drive.map { AirlockClient(baseURL: $0.baseURL) }
        items = ItemMap(domain: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {}

    // MARK: - Lookup

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let item = try await lookup(identifier)
                reached()
                completionHandler(item, nil)
            } catch {
                completionHandler(nil, mapError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    /// Items come from listing the parent directory: airlockd has no stat.
    func lookup(_ identifier: NSFileProviderItemIdentifier) async throws -> NSFileProviderItem {
        let (client, drive) = try ready()
        if identifier == .rootContainer {
            return FileProviderItem.root(name: domain.displayName, writable: try await writable(client, drive))
        }
        guard let path = items.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
        let parent = parentPath(path)
        let name = (path as NSString).lastPathComponent
        let listing = try await client.list(drive.share, path: parent)
        guard let entry = listing.entries.first(where: { $0.name == name }) else {
            items.remove(path)
            throw NSFileProviderError(.noSuchItem)
        }
        return makeItem(entry, in: parent, writable: try await writable(client, drive))
    }

    func makeItem(_ entry: FileEntry, in dir: String, writable: Bool) -> FileProviderItem {
        let path = joinPath(dir, entry.name)
        return FileProviderItem(identifier: items.identifier(for: path), parent: items.identifier(for: dir),
                                name: entry.name, isDir: entry.isDir, size: entry.size,
                                modified: entry.modified, writable: writable)
    }

    private var cachedWritable: Bool?

    /// Write-protected media (SD lock switch) is read-only for Files too.
    func writable(_ client: AirlockClient, _ drive: DriveDomainID) async throws -> Bool {
        if let cachedWritable { return cachedWritable }
        // Not listed (yet, or any more): the airlock answered, so this
        // isn't "unreachable". Read-only until it's listed; not cached.
        guard let d = try await client.drives().first(where: { $0.shareName == drive.share }) else {
            return false
        }
        cachedWritable = !d.readOnly
        return !d.readOnly
    }

    func ready() throws -> (AirlockClient, DriveDomainID) {
        guard let client, let drive else { throw NSFileProviderError(.notAuthenticated) }
        return (client, drive)
    }

    // MARK: - Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let task = Task {
            do {
                let (client, drive) = try ready()
                guard let path = items.path(for: itemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                let item = try await lookup(itemIdentifier)
                let dst = try temporaryFile(named: (path as NSString).lastPathComponent)
                let (tmp, resp) = try await URLSession.shared.download(from: client.downloadURL(drive.share, path: path))
                if let http = resp as? HTTPURLResponse, http.statusCode == 404 { throw NSFileProviderError(.noSuchItem) }
                if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw AirlockError(status: http.statusCode, message: "download failed")
                }
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
                progress.completedUnitCount = 100
                reached()
                completionHandler(dst, item, nil)
            } catch {
                completionHandler(nil, nil, mapError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func temporaryFile(named name: String) throws -> URL {
        let dir = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL()
            ?? FileManager.default.temporaryDirectory
        let sub = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub.appendingPathComponent(name)
    }

    // MARK: - Changes from Files

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let (client, drive) = try ready()
                guard let dir = items.path(for: itemTemplate.parentItemIdentifier) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let path = joinPath(dir, itemTemplate.filename)
                if itemTemplate.contentType == .folder {
                    try await client.makeDirectory(drive.share, path: path)
                } else if itemTemplate.contentType == .symbolicLink || itemTemplate.contentType == .aliasFile {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
                } else {
                    let file = try url ?? emptyFile()
                    try await client.upload(drive.share, path: path, from: file)
                }
                let item = try await lookup(items.identifier(for: path))
                completionHandler(item, [], false, nil)
            } catch {
                completionHandler(nil, [], false, mapError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let (client, drive) = try ready()
                guard var path = items.path(for: item.itemIdentifier) else { throw NSFileProviderError(.noSuchItem) }

                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    guard let dir = items.path(for: item.parentItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                    let target = joinPath(dir, item.filename)
                    if target != path {
                        try await client.move(drive.share, from: path, to: target)
                        items.move(from: path, to: target)
                        path = target
                    }
                }
                if changedFields.contains(.contents), let newContents {
                    try await client.upload(drive.share, path: path, from: newContents)
                }
                // Dates, tags, favourites, last used: airlockd can't store
                // them, so they're accepted and dropped. Reporting them as
                // still pending makes Files retry forever and badge the
                // app with a sync problem.
                let updated = try await lookup(item.itemIdentifier)
                completionHandler(updated, [], false, nil)
            } catch {
                completionHandler(nil, [], false, mapError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let (client, drive) = try ready()
                guard let path = items.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
                try await client.remove(drive.share, path: path)
                items.remove(path)
                completionHandler(nil)
            } catch {
                completionHandler(mapError(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    private func emptyFile() throws -> URL {
        let url = try temporaryFile(named: "empty")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet || containerItemIdentifier == .trashContainer {
            return EmptyEnumerator()
        }
        guard let path = items.path(for: containerItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
        return FolderEnumerator(ext: self, path: path)
    }

    // MARK: - Errors

    /// Files shows "server unreachable" with a retry for network
    /// failures; daemon 404s are missing items; 403 is read-only media.
    func mapError(_ error: Error) -> Error {
        if error is NSFileProviderError { return error }
        if let e = error as? AirlockError {
            switch e.status {
            case 404: return NSFileProviderError(.noSuchItem)
            case 403: return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                     userInfo: [NSLocalizedDescriptionKey: e.message])
            case 409: return NSFileProviderError(.filenameCollision)
            default: return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                    userInfo: [NSLocalizedDescriptionKey: e.localizedDescription])
            }
        }
        if (error as NSError).domain == NSURLErrorDomain { return unreachable() }
        return error
    }

    func unreachable() -> NSFileProviderError {
        unreachableLock.withLock { reportedUnreachable = true }
        return NSFileProviderError(.serverUnreachable)
    }

    /// A request went through: clear an earlier "server unreachable".
    func reached() {
        let wasReported = unreachableLock.withLock {
            defer { reportedUnreachable = false }
            return reportedUnreachable
        }
        guard wasReported, let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalErrorResolved(NSFileProviderError(.serverUnreachable)) { _ in }
    }
}

/// Lists one folder. airlockd can't say what changed since a point in
/// time, so a change request answers "anchor expired" and Files lists
/// the folder again.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    let ext: FileProviderExtension
    let path: String

    init(ext: FileProviderExtension, path: String) {
        self.ext = ext
        self.path = path
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let (client, drive) = try ext.ready()
                let writable = try await ext.writable(client, drive)
                let listing = try await client.list(drive.share, path: path)
                observer.didEnumerate(listing.entries.map { ext.makeItem($0, in: path, writable: writable) })
                observer.finishEnumerating(upTo: nil)
                ext.reached()
            } catch {
                observer.finishEnumeratingWithError(ext.mapError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("\(Date().timeIntervalSince1970)".utf8)))
    }
}

/// Working set and trash: airlockd has neither, so nothing to report.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    private static let anchor = NSFileProviderSyncAnchor(Data("0".utf8))

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: Self.anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor)
    }
}
