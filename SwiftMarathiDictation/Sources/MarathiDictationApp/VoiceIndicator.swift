import AppKit

@MainActor
final class IndicatorView: NSView {
    var state: IndicatorState = .recording {
        didSet { needsDisplay = true }
    }
    var phase: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        NSColor(calibratedWhite: 0.06, alpha: 0.82).setFill()
        pill.fill()

        let stroke = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 1.0, alpha: 0.32).setStroke()
        stroke.lineWidth = 1
        stroke.stroke()

        switch state {
        case .recording:
            drawBars()
        case .processing:
            drawSpinner()
        }
    }

    private func drawBars() {
        NSColor(calibratedWhite: 1.0, alpha: 0.92).setFill()
        let centerY = bounds.height / 2
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 5
        let startX = (bounds.width - (5 * barWidth + 4 * spacing)) / 2
        for index in 0..<5 {
            let wave = 0.5 + 0.5 * sin(phase + CGFloat(index) * 0.9)
            let height = 4 + wave * 12
            let rect = NSRect(x: startX + CGFloat(index) * (barWidth + spacing), y: centerY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawSpinner() {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 6
        for index in 0..<8 {
            let alpha = 0.18 + 0.82 * CGFloat((index + Int(phase)) % 8) / 7
            NSColor(calibratedWhite: 1.0, alpha: alpha).setFill()
            let angle = CGFloat.pi * 2 * CGFloat(index) / 8
            let rect = NSRect(
                x: center.x + cos(angle) * radius - 1.4,
                y: center.y + sin(angle) * radius - 1.4,
                width: 2.8,
                height: 2.8
            )
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

enum IndicatorState {
    case recording
    case processing
}

@MainActor
final class VoiceIndicator {
    private let window: NSWindow
    private let view: IndicatorView
    private var timer: Timer?
    private var visibleState: IndicatorState?
    private var phase: CGFloat = 0

    init() {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let size = NSSize(width: 74, height: 24)
        let rect = NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 36,
            width: size.width,
            height: size.height
        )
        view = IndicatorView(frame: NSRect(origin: .zero, size: size))
        window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.canHide = false
        window.contentView = view
    }

    func showRecording() {
        visibleState = .recording
        view.state = .recording
        window.orderFrontRegardless()
        startTimer()
    }

    func showProcessing() {
        visibleState = .processing
        view.state = .processing
        window.orderFrontRegardless()
        startTimer()
    }

    func hide() {
        visibleState = nil
        window.orderOut(nil)
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        if timer != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let visibleState else { return }
        switch visibleState {
        case .recording:
            phase += 0.45
        case .processing:
            phase = CGFloat((Int(phase) + 1) % 8)
        }
        view.phase = phase
    }
}
