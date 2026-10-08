import Foundation
import SwiftData

public enum ModelContainerFactory {
    public static var schema: Schema {
        Schema([
            Notebook.self, Shelf.self, CustomThemeRecord.self,
            AppPreferences.self, NovaChat.self
        ])
    }

    /// What had to happen for the app to get a library database at all.
    public enum Recovery: Sendable, Equatable {
        /// The database couldn't be opened. It was moved, untouched, into this
        /// folder, and a fresh one was created; the library is rebuilt from the
        /// notebook packages on disk (`NotebookRepository.reconcileWithDisk`).
        case movedAside(URL)
        /// Not even a fresh database could be opened, so this session keeps the
        /// library in memory. The notebooks themselves are files and are safe.
        case inMemoryOnly
    }

    public static func make(inMemory: Bool = false) -> ModelContainer {
        makeRecovering(inMemory: inMemory).container
    }

    /// Opens the library database, recovering instead of hiding the notes.
    ///
    /// The fallback used to be an in-memory store straight away. That launched,
    /// but onto an EMPTY library — every notebook's ink still on disk with no
    /// row to list it — and anything created in that session vanished at the
    /// next launch. Now the unopenable database is moved aside (kept, never
    /// deleted: it holds settings, custom themes and chats that might be
    /// recoverable), a fresh one is opened in its place, and the caller rebuilds
    /// the library from the packages. In-memory is the last resort, and it is
    /// reported as such.
    ///
    /// `url` exists for tests; the app uses SwiftData's default location.
    public static func makeRecovering(
        inMemory: Bool = false, url: URL? = nil
    ) -> (container: ModelContainer, recovery: Recovery?) {
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return (container, nil)
        }
        if !inMemory, let aside = moveAside(storeAt: configuration.url),
           let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return (container, .movedAside(aside))
        }
        let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return (try ModelContainer(for: schema, configurations: [fallback]), .inMemoryOnly)
        } catch {
            fatalError("Unable to create even an in-memory model container: \(error)")
        }
    }

    /// Moves a store and its `-wal`/`-shm` companions into
    /// `Recovered Library/<time>/` beside it. Returns the folder, or nil if there
    /// was nothing to move (in which case a retry can't do any better).
    static func moveAside(storeAt url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let stamp = Int64(Date.now.timeIntervalSince1970 * 1000)
        let folder = url.deletingLastPathComponent()
            .appendingPathComponent("Recovered Library", isDirectory: true)
            .appendingPathComponent("\(stamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.moveItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
        }
        return fm.fileExists(atPath: url.path) ? nil : folder
    }
}
