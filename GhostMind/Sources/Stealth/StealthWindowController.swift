import AppKit
import SwiftUI

// MARK: - Stealth NSWindow

final class GhostWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
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
        hidesOnDeactivate = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = true
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
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.init(window: window)

        // Perfectly center on current main screen
        if let screen = NSScreen.main {
            let x = (screen.visibleFrame.width - initialFrame.width) / 2
            let y = (screen.visibleFrame.height - initialFrame.height) / 2
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + x, y: screen.visibleFrame.minY + y))
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
            name: Constants.Notification.collapseStateChanged,
            object: nil
        )

        // Local monitor for Escape key
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                NotificationCenter.default.post(name: Constants.Notification.escapePressed, object: nil)
                return nil // consume event
            }
            return event
        }
    }

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


