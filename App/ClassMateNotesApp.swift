import NotesModels
import NotesServices
import SwiftData
import SwiftUI

@main
struct ClassMateNotesApp: App {
    private let container: ModelContainer
    @State private var services: AppServices

    init() {
        let container = ModelContainerFactory.make()
        self.container = container
        let services = AppServices(modelContainer: container)
        self._services = State(initialValue: services)
        services.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .environment(services.entitlements)
        }
        .modelContainer(container)
    }
}
