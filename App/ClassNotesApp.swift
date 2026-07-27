import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

@main
struct ClassNotesApp: App {
    private let container: ModelContainer
    @State private var services: AppServices

    init() {
        CMFonts.registerIfNeeded()
        CMType.applyNavigationBarAppearance()
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
                // Cabinet Grotesk is the app's voice, exactly as in ClassMate. The
                // type scale (`Font.dsBody` & co.) covers everything that names a
                // style; this catches everything that doesn't — plain `Text`, list
                // rows, alerts, pickers.
                .environment(\.font, .dsBody)
        }
        .modelContainer(container)
    }
}
