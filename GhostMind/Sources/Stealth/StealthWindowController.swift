import AppKit
import SwiftUI

// MARK: - Stealth NSWindow

final class GhostWindow: NSWindow {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    private func configure() {
        sharingType = .none
        ignoresMouseEvents = false
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - StealthWindowController

final class StealthWindowController: NSWindowController {

    private var hostingView: NSHostingView<MainOverlayView>?
    private var isVisible = true

    // Frame sizes
    static let expandedSize = NSSize(width: 840, height: 580)
    static let collapsedSize = NSSize(width: 320, height: 52)

    convenience init() {
        let initialFrame = NSRect(
            origin: .zero,
            size: StealthWindowController.expandedSize
        )
        let window = GhostWindow(
            contentRect: initialFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.init(window: window)

        // Center top-center of main screen
        if let screen = NSScreen.main {
            let x = (screen.frame.width - initialFrame.width) / 2
            let y = screen.frame.height * 0.72
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let rootView = MainOverlayView()
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = window.contentView?.bounds ?? initialFrame
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        self.hostingView = hosting

        // Observe collapse state changes from SwiftUI
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCollapseChange(_:)),
            name: .collapseStateChanged,
            object: nil
        )
    }

    // MARK: - Collapse / Expand Window Resize

    @objc private func handleCollapseChange(_ note: Notification) {
        guard let collapsed = note.object as? Bool,
              let window else { return }

        let targetSize = collapsed
            ? StealthWindowController.collapsedSize
            : StealthWindowController.expandedSize

        // Keep top-left corner fixed while resizing
        let currentFrame = window.frame
        let newOriginY = currentFrame.maxY - targetSize.height
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: newOriginY,
            width: targetSize.width,
            height: targetSize.height
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Toggle visibility (⌘⇧H)

    func toggleVisibility() {
        guard let w = window else { return }
        if isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                w.animator().alphaValue = 0
            } completionHandler: {
                w.orderOut(nil)
                self.isVisible = false
            }
        } else {
            w.alphaValue = 0
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                w.animator().alphaValue = 1
            }
            isVisible = true
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let collapseStateChanged = Notification.Name("GhostMind.collapseStateChanged")
}
