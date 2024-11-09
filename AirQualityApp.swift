import SwiftUI
import AppKit

@main
struct AirQualityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup is needed, so this is left empty.
        Settings {
            EmptyView() // Optional: This suppresses any app window entirely.
        }
    }
}
