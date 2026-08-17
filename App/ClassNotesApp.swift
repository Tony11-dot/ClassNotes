import NotesDesignSystem
import NotesModels
import NotesServices
import SwiftData
import SwiftUI

@main
struct ClassNotesApp: App {
    private let container: ModelContainer
    @State private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase

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
                // Coming back to the app is when a notebook drawn on another
                // device is most likely to be waiting — re-pull then, not
                // only at launch. `refreshRemoteLibrary` throttles itself, so
                // a quick background/foreground flicker doesn't double-fire.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await services.refreshRemoteLibrary() }
                }
        }
        .modelContainer(container)
    }
}
