import SwiftUI

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No window scene — the AppDelegate owns the menu-bar status item + popover.
        Settings { EmptyView() }
    }
}
