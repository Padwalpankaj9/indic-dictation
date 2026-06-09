import AppKit
import ApplicationServices

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
    private(set) var isListening = false
    private(set) var tapLocationDescription = "none"
    private(set) var lastEventSummary = "none"
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil, runLoopSource == nil else { return }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let (tap, locationDescription) = createEventTap(mask: mask) else {
            lastEventSummary = "Fn event tap unavailable"
            tapLocationDescription = "none"
            isListening = false
            NSLog("Indic Dictation: Fn event tap unavailable")
            return
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            eventTap = nil
            lastEventSummary = "Fn event tap source unavailable"
            tapLocationDescription = "none"
            isListening = false
            NSLog("Indic Dictation: Fn event tap source unavailable")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isListening = true
        tapLocationDescription = locationDescription
        lastEventSummary = "Fn event tap ready via \(locationDescription)"
        NSLog("Indic Dictation: Fn event tap ready via \(locationDescription)")
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        tapLocationDescription = "none"
        isListening = false
        isDown = false
    }

    private func createEventTap(mask: CGEventMask) -> (tap: CFMachPort, locationDescription: String)? {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let locations: [(CGEventTapLocation, String)] = [
            (.cghidEventTap, "HID"),
            (.cgSessionEventTap, "session")
        ]

        for (location, description) in locations {
            if let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.eventTapCallback,
                userInfo: userInfo
            ) {
                return (tap, description)
            }
        }

        return nil
    }

    private func handle(keyCode: Int, flags: CGEventFlags) {
        let hasFunctionFlag = flags.contains(.maskSecondaryFn)
        lastEventSummary = "keyCode \(keyCode), Fn flag \(hasFunctionFlag ? "down" : "up")"

        guard keyCode == Self.functionKeyCode else {
            if !hasFunctionFlag {
                isDown = false
            }
            return
        }

        // A flagsChanged event for key code 63 means Fn toggled. On release,
        // the flag may be gone; if we were already down, treat it as key-up.
        if hasFunctionFlag && !isDown {
            isDown = true
        } else if isDown {
            isDown = false
        }
    }

    private func markTapDisabled(_ reason: String) {
        lastEventSummary = reason
        isDown = false
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<FunctionKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout {
            DispatchQueue.main.async {
                Task { @MainActor in
                    monitor.markTapDisabled("Fn event tap timeout; re-enabled")
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            DispatchQueue.main.async {
                Task { @MainActor in
                    monitor.markTapDisabled("Fn event tap disabled by user input; re-enabled")
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        DispatchQueue.main.async {
            Task { @MainActor in
                monitor.handle(keyCode: keyCode, flags: flags)
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
