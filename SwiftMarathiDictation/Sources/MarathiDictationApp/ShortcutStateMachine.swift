import Foundation

enum ShortcutMode {
    case idle
    case holdRecording
    case lockedRecording
}

final class ShortcutStateMachine {
    private let holdStartSeconds: TimeInterval = 0.25
    private let doubleTapSeconds: TimeInterval = 0.60

    private let startRecording: (Bool) -> Void
    private let stopRecording: () -> Void
    private let statusChanged: (String) -> Void

    private var mode: ShortcutMode = .idle
    private var wasPressed = false
    private var pressStartedAt: TimeInterval?
    private var firstTapAt: TimeInterval?
    private var tapCount = 0

    init(
        startRecording: @escaping (Bool) -> Void,
        stopRecording: @escaping () -> Void,
        statusChanged: @escaping (String) -> Void
    ) {
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.statusChanged = statusChanged
    }

    func reset(notify: Bool = true) {
        if mode == .holdRecording || mode == .lockedRecording {
            stopRecording()
        }
        mode = .idle
        wasPressed = false
        pressStartedAt = nil
        firstTapAt = nil
        tapCount = 0
        if notify {
            statusChanged("Ready")
        }
    }

    func update(isPressed: Bool, now: TimeInterval) {
        if let firstTapAt, now - firstTapAt > doubleTapSeconds {
            clearTaps()
        }

        if isPressed && !wasPressed {
            onPress(now: now)
        } else if !isPressed && wasPressed {
            onRelease(now: now)
        } else if isPressed, mode == .idle, let pressStartedAt, now - pressStartedAt >= holdStartSeconds {
            startHoldRecording()
        }

        wasPressed = isPressed
    }

    private func onPress(now: TimeInterval) {
        pressStartedAt = now
        if mode == .lockedRecording {
            statusChanged("Locked recording. Release shortcut to stop.")
        } else {
            statusChanged("Shortcut pressed")
        }
    }

    private func onRelease(now: TimeInterval) {
        if mode == .holdRecording || mode == .lockedRecording {
            mode = .idle
            stopRecording()
            clearTaps()
            statusChanged("Translating...")
            return
        }

        registerTap(now: now)
    }

    private func registerTap(now: TimeInterval) {
        if firstTapAt == nil || now - (firstTapAt ?? 0) > doubleTapSeconds {
            firstTapAt = now
            tapCount = 1
            statusChanged("Tap once more to lock recording")
            return
        }

        tapCount += 1
        if tapCount >= 2 {
            clearTaps()
            mode = .lockedRecording
            startRecording(true)
            statusChanged("Locked recording. Tap shortcut once to stop.")
        }
    }

    private func startHoldRecording() {
        mode = .holdRecording
        clearTaps()
        startRecording(false)
        statusChanged("Hold recording. Release shortcut to stop.")
    }

    private func clearTaps() {
        firstTapAt = nil
        tapCount = 0
        pressStartedAt = nil
    }
}
