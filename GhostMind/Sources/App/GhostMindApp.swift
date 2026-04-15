import SwiftUI
import AppKit

@main
struct GhostMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup — fully controlled by AppDelegate
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: StealthWindowController?
    private var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock and Cmd+Tab switcher
        NSApp.setActivationPolicy(.accessory)

        // Launch the main stealth overlay window
        windowController = StealthWindowController()
        windowController?.showWindow(nil)

        // Register global keyboard shortcuts
        hotKeyManager = HotKeyManager(windowController: windowController)
        hotKeyManager?.register()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
