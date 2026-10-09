import Foundation

/// Where notebooks travel between the user's devices (D-003): a folder that
/// another device sees too. iCloud Drive in the app; any local folder in
/// tests, so the whole sync — two devices and the folder between them — runs
/// without an Apple ID.
public protocol CloudDrive: Sendable {
    /// The folder notebook packages live in, or nil when it isn't available
    /// (signed out of iCloud, or iCloud Drive off for ClassNotes).
    func folder() async -> URL?
    /// Makes sure every file of `package` is on this device. False when it
    /// isn't yet: the notebook is skipped this time and tried again later.
    func download(_ package: URL) async -> Bool
}

/// A plain folder, for tests (and anything else that is just a folder).
public struct FolderDrive: CloudDrive {
    let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func folder() async -> URL? {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public func download(_ package: URL) async -> Bool { true }
}

/// The app's iCloud container (`iCloud.com.classmate.notes`, already in the
/// entitlements), in a `Notebooks` folder that the Files app doesn't show:
/// these are the app's working copies, not documents to rename by hand.
public struct ICloudDrive: CloudDrive {
    /// How long one notebook may take to download before it waits for the
    /// next pass.
    static let downloadTimeout: Duration = .seconds(90)

    public init() {}

    public func folder() async -> URL? {
        // Can block while iCloud sets the container up: never on the main actor.
        await Task.detached(priority: .utility) {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
            let folder = container.appendingPathComponent("Notebooks", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }.value
    }

    public func download(_ package: URL) async -> Bool {
        let fm = FileManager.default
        let placeholder = package.deletingLastPathComponent()
            .appendingPathComponent(".\(package.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) || !fm.fileExists(atPath: package.path) {
            try? fm.startDownloadingUbiquitousItem(at: package)
        }
        let deadline = ContinuousClock.now + Self.downloadTimeout
        while ContinuousClock.now < deadline {
            let pending = Self.notDownloaded(in: package)
            if pending.isEmpty, fm.fileExists(atPath: package.path) { return true }
            for url in pending { try? fm.startDownloadingUbiquitousItem(at: url) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Files in `package` that are still only in iCloud.
    static func notDownloaded(in package: URL) -> [URL] {
        let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys) else {
            return []
        }
        var pending: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                pending.append(url.deletingLastPathComponent()
                    .appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count))))
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                pending.append(url)
            }
        }
        return pending
    }
}

/// File operations on the shared folder, coordinated so they never collide
/// with iCloud writing the same files. Coordination costs nothing on a plain
/// folder, so tests run the very same code.
enum CoordinatedFiles {
    enum Failure: Error { case coordination(NSError) }

    static func read<T>(_ url: URL, _ work: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try work(url) }
        }
        if let coordinationError { throw Failure.coordination(coordinationError) }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func write(_ url: URL, options: NSFileCoordinator.WritingOptions = [], _ work: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do { try work(url) } catch { failure = error }
        }
        if let coordinationError { throw Failure.coordination(coordinationError) }
        if let failure { throw failure }
    }

    static func move(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            do {
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: from, to: to)
            } catch { failure = error }
        }
        if let coordinationError { throw Failure.coordination(coordinationError) }
        if let failure { throw failure }
    }
}
