import AppKit

/// Tracks whether the real Fn / Globe key is held down.
///
/// macOS turns on the same "secondary function" flag for the arrow keys and
/// other navigation keys, not just the Fn key. So reading that flag alone
/// cannot tell a real Fn press apart from someone moving the cursor with the
/// arrows, which is what made dictation start on its own. flagsChanged events
/// carry the key code, and only the physical Fn / Globe key reports key code
/// 63, so filtering on it keeps the Fn shortcut honest.
@MainActor
final class FunctionKeyMonitor {
    private static let functionKeyCode: UInt16 = 63

    private(set) var isDown = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        // Other apps hold focus while you dictate, so watch their key events.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }

        // Also catch the Fn key while one of our own windows is frontmost.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        // Ignore every modifier change except the Fn / Globe key itself.
        guard event.keyCode == Self.functionKeyCode else { return }
        // The function flag stays on only while the Fn key is actually held.
        isDown = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.function)
    }
}
