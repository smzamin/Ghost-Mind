import Carbon
import AppKit

/// Registers system-wide keyboard shortcuts using Carbon's `RegisterEventHotKey`.
/// This works even when another app is frontmost.
final class HotKeyManager {

    private weak var windowController: StealthWindowController?
    private var hotKeyRefs: [EventHotKeyRef?] = []

    init(windowController: StealthWindowController?) {
        self.windowController = windowController
    }

    func register() {
        // ⌘⇧H — Toggle show/hide
        registerHotKey(keyCode: UInt32(kVK_ANSI_H),
                       modifiers: UInt32(cmdKey | shiftKey),
                       id: 1) { [weak self] in
            // Dispatch to MainActor since toggleVisibility is @MainActor-isolated
            Task { @MainActor in self?.windowController?.toggleVisibility() }
        }

        // ⌘↩ — Instant Assist
        registerHotKey(keyCode: UInt32(kVK_Return),
                       modifiers: UInt32(cmdKey),
                       id: 2) {
            NotificationCenter.default.post(name: Constants.Notification.instantAssist, object: nil)
        }

        // ⌘⇧T — Toggle transcript panel
        registerHotKey(keyCode: UInt32(kVK_ANSI_T),
                       modifiers: UInt32(cmdKey | shiftKey),
                       id: 3) {
            NotificationCenter.default.post(name: Constants.Notification.toggleTranscript, object: nil)
        }

        // ⌘⇧S — Read Screen (Vision OCR)
        registerHotKey(keyCode: UInt32(kVK_ANSI_S),
                       modifiers: UInt32(cmdKey | shiftKey),
                       id: 4) {
            NotificationCenter.default.post(name: Constants.Notification.readScreen, object: nil)
        }
    }

    // MARK: - Private

    private struct HotKeyCallback {
        let id: UInt32
        let action: () -> Void
    }

    // Static storage so Carbon C callbacks can reach Swift closures
    // @MainActor ensures thread-safe access from DispatchQueue.main.async
    @MainActor static var callbacks: [UInt32: () -> Void] = [:]

    private func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        id: UInt32,
        action: @escaping () -> Void
    ) {
        Task { @MainActor in HotKeyManager.callbacks[id] = action }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x474D494E) // 'GMIN'
        hotKeyID.id = id

        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        hotKeyRefs.append(ref)

        // Install event handler once
        if hotKeyRefs.count == 1 {
            installEventHandler()
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                
                let hotKeyIDCopy = hotKeyID.id
                
                // If ⌘↩ (id 2) is pressed while GhostMind is active, let it pass through to the local handler
                // in InputBar.swift instead of triggering the global Instant Assist notification.
                if hotKeyIDCopy == 2 && NSApplication.shared.isActive {
                    return OSStatus(eventNotHandledErr)
                }
                
                Task { @MainActor in
                    HotKeyManager.callbacks[hotKeyIDCopy]?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }
}

// MARK: - Notification Names

