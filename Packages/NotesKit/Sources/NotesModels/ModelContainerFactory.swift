import Foundation
import SwiftData

public enum ModelContainerFactory {
    public static var schema: Schema {
        Schema([
            Notebook.self, Shelf.self, CustomThemeRecord.self,
            AppPreferences.self, NovaChat.self
        ])
    }

    /// Persistent container, falling back to in-memory rather than crashing at
    /// launch if the store is unopenable — notebooks' ink is on disk and safe
    /// regardless.
    public static func make(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Unable to create even an in-memory model container: \(error)")
            }
        }
    }
}
