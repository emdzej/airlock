import AirlockKit
import FileProvider
import UniformTypeIdentifiers

/// A file or folder on the drive, as Files sees it.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let creationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    let capabilities: NSFileProviderItemCapabilities

    init(identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier,
         name: String, isDir: Bool, size: Int64, modified: Date?, writable: Bool) {
        itemIdentifier = identifier
        parentItemIdentifier = parent
        filename = name
        contentType = isDir ? .folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        documentSize = isDir ? nil : NSNumber(value: size)
        contentModificationDate = modified
        creationDate = modified
        // Size + mtime stand in for an ETag: airlockd has none.
        let stamp = Data("\(size)|\(modified?.timeIntervalSince1970 ?? 0)".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: stamp, metadataVersion: stamp + Data(name.utf8))
        var caps: NSFileProviderItemCapabilities = isDir ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
        if writable {
            caps.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting])
            caps.formUnion(isDir ? [.allowsAddingSubItems] : [.allowsWriting])
        }
        capabilities = caps
    }

    static func root(name: String, writable: Bool) -> FileProviderItem {
        FileProviderItem(identifier: .rootContainer, parent: .rootContainer, name: name,
                         isDir: true, size: 0, modified: nil, writable: writable)
    }
}
