import AppKit
import SwiftUI

enum IndicatorState {
    case recording
    case processing
}

/// Shared state the SwiftUI panel observes. Updated rarely (state + text),
/// so there is no per-frame publishing. Loudness is read from the meter instead.
@MainActor
final class IndicatorModel: ObservableObject {
    @Published var state: IndicatorState = .recording
    @Published var previewText: String = ""
    let meter: AudioLevelMeter

    init(meter: AudioLevelMeter) {
        self.meter = meter
    }
}

@MainActor
final class VoiceIndicator {
    /// Audio thread writes loudness here; the waveform reads it each frame.
    let meter = AudioLevelMeter()

    private let window: NSWindow
    private let model: IndicatorModel
    private var preferredTargetFrame: NSRect?

    init() {
        model = IndicatorModel(meter: meter)

        let rect = Self.windowFrame(for: Self.targetScreen())

        let hosting = NSHostingView(rootView: IndicatorRoot(model: model))
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        hosting.autoresizingMask = [.width, .height]

        window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = hosting
    }

    func showRecording(targetFrame: CGRect? = nil) {
        // Note: does NOT touch the text. START_SPEECH calls this repeatedly,
        // and clearing here is what made the preview flicker.
        if let targetFrame {
            preferredTargetFrame = NSRect(origin: targetFrame.origin, size: targetFrame.size)
        }
        model.state = .recording
        moveToActiveSpaceIfNeeded(force: targetFrame != nil)
        window.orderFrontRegardless()
    }

    func showProcessing() {
        // Keep the text visible through finalizing so it never blinks away.
        model.state = .processing
        moveToActiveSpaceIfNeeded(force: false)
        window.orderFrontRegardless()
    }

    func setPreview(_ text: String) {
        // Ignore empty interims so the line stays put instead of flickering.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preview = String(text.suffix(260))
        guard model.previewText != preview else { return }
        model.previewText = preview
    }

    func clearPreview() {
        // Called once at the very start of a new dictation.
        model.previewText = ""
        meter.reset()
    }

    func hide() {
        // Order out first, then wipe the text while the window is already off
        // screen, so the old subtitle can never flash back on the next session.
        window.orderOut(nil)
        model.previewText = ""
        meter.reset()
        preferredTargetFrame = nil
    }

    private func moveToActiveSpaceIfNeeded(force: Bool) {
        guard force || !window.isVisible else { return }
        if window.isVisible {
            // Re-showing lets AppKit attach the panel to the current Space.
            window.orderOut(nil)
        }
        window.setFrame(Self.windowFrame(for: Self.targetScreen(for: preferredTargetFrame)), display: true)
    }

    private static func targetScreen(for targetFrame: NSRect? = nil) -> NSScreen {
        if let targetFrame,
           let screen = screen(containing: NSPoint(x: targetFrame.midX, y: targetFrame.midY)) {
            return screen
        }

        let mouseLocation = NSEvent.mouseLocation
        if let screen = screen(containing: mouseLocation) {
            return screen
        }
        return NSScreen.screens.min { lhs, rhs in
            distanceSquared(from: mouseLocation, to: lhs.frame) < distanceSquared(from: mouseLocation, to: rhs.frame)
        } ?? NSScreen.main!
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func windowFrame(for screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let width = min(max(visibleFrame.width - 64, 320), 720)
        let height: CGFloat = 220
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY,
            width: width,
            height: height
        )
    }

    private static func distanceSquared(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

// MARK: - SwiftUI panel

private struct IndicatorRoot: View {
    @ObservedObject var model: IndicatorModel

    private var hasText: Bool { !model.previewText.isEmpty }

    var body: some View {
        VStack(spacing: 14) {
            if hasText {
                PreviewLabel(text: model.previewText)
                    .transition(.opacity)
            }
            glyphPill
        }
        .animation(.easeOut(duration: 0.2), value: hasText)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 18)
    }

    // No pill, no border: just the light trails floating over the screen.
    private var glyphPill: some View {
        LightWaves(meter: model.meter, state: model.state)
            .frame(width: 300, height: 48)
            // A whisper of dark shadow keeps the trails readable on white pages.
            .shadow(color: .black.opacity(0.45), radius: 2.5, x: 0, y: 1)
    }
}

/// Real macOS vibrancy (blurs whatever is behind the window), not a flat fill.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Braided strands of warm light that breathe with the voice, inspired by
/// long-exposure light trails. Pure Canvas drawing on a timeline, so it never
/// touches the audio or network path.
/// Each strand is one thin ribbon of light with its own rhythm, so the
/// bundle weaves and crosses instead of moving in lockstep.
private struct WaveStrand: Sendable {
    let cycles: Double      // full waves across the pill
    let weave: Double       // slow secondary undulation
    let speed: Double       // drift speed (points per second of phase)
    let phase: Double
    let amp: CGFloat        // share of the available height
    let brightness: CGFloat
}

/// Design constants live at file scope so the nonisolated WaveState class
/// can read them without tripping main-actor isolation.
private enum WaveDesign {
    static let strands: [WaveStrand] = [
        WaveStrand(cycles: 1.6, weave: 0.7, speed: 1.9, phase: 0.0, amp: 1.00, brightness: 1.00),
        WaveStrand(cycles: 2.1, weave: 0.5, speed: -1.4, phase: 2.1, amp: 0.85, brightness: 0.80),
        WaveStrand(cycles: 1.3, weave: 0.9, speed: 1.1, phase: 4.0, amp: 0.70, brightness: 0.66),
        WaveStrand(cycles: 2.6, weave: 0.4, speed: -2.3, phase: 1.2, amp: 0.55, brightness: 0.55),
        WaveStrand(cycles: 1.9, weave: 0.6, speed: 0.7, phase: 5.1, amp: 0.42, brightness: 0.45)
    ]

    /// ~0.8s of voice history at 45fps; a syllable takes that long to travel
    /// from the center out to the tips, so the wave calms fast after speech.
    static let historyCount = 36
}

private struct LightWaves: View {
    let meter: AudioLevelMeter
    let state: IndicatorState

    private static let coreColor = Color(red: 1.0, green: 0.97, blue: 0.90)
    private static let glowColor = Color(red: 1.0, green: 0.80, blue: 0.55)

    /// Mutable per-frame state. Holds the loudness history that sculpts the
    /// wave, and the accumulated phase per strand so speed changes smoothly.
    private final class WaveState {
        var levels: [CGFloat] = Array(repeating: 0, count: WaveDesign.historyCount)
        var phases: [Double] = WaveDesign.strands.map(\.phase)
        var lastTime: TimeInterval?

        func push(_ level: CGFloat) {
            levels.removeFirst()
            levels.append(level)
        }
    }

    @State private var waveState = WaveState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let isProcessing = state == .processing
                let level = isProcessing ? 0 : CGFloat(meter.value)
                let voice = min(1, pow(max(level, 0.0001) * 2.4, 0.72))

                // Record this instant; the buffer IS the wave's shape.
                waveState.push(voice)

                // Advance each strand by elapsed time. Speech winds the braid
                // up to ~4x idle speed; silence lets it relax. Accumulating
                // phase (instead of multiplying time) avoids jumps.
                let dt = min(0.1, t - (waveState.lastTime ?? t))
                waveState.lastTime = t
                let tempo = isProcessing ? 0.3 : 0.55 + Double(voice) * 3.4
                for index in WaveDesign.strands.indices {
                    waveState.phases[index] += dt * WaveDesign.strands[index].speed * tempo
                }

                let dim: CGFloat = isProcessing ? 0.55 : 0.62 + 0.38 * voice
                let midY = size.height / 2
                let halfHeight = (size.height / 2) - 2
                let breathing = 0.10 + 0.035 * CGFloat(sin(t * 1.8))

                for (index, strand) in WaveDesign.strands.enumerated() {
                    let path = strandPath(
                        strand,
                        phase: waveState.phases[index],
                        size: size,
                        midY: midY,
                        halfHeight: halfHeight,
                        breathing: breathing
                    )
                    let glow = strand.brightness * dim
                    // Dark contour first so the trails stay visible over white
                    // pages now that the glass pill is gone, then the light.
                    context.stroke(path, with: .color(Color.black.opacity(0.20 * glow)), lineWidth: 5.6)
                    context.stroke(path, with: .color(Self.glowColor.opacity(0.12 * glow)), lineWidth: 4.4)
                    context.stroke(path, with: .color(Self.glowColor.opacity(0.28 * glow)), lineWidth: 2.1)
                    context.stroke(path, with: .color(Self.coreColor.opacity(0.95 * glow)), lineWidth: 1.0)
                }
            }
        }
    }

    private func strandPath(
        _ strand: WaveStrand,
        phase: Double,
        size: CGSize,
        midY: CGFloat,
        halfHeight: CGFloat,
        breathing: CGFloat
    ) -> Path {
        var path = Path()
        let width = size.width
        let step: CGFloat = 2.0
        let levels = waveState.levels
        let lastIndex = levels.count - 1
        var x: CGFloat = 0
        while x <= width {
            let u = Double(x / width)
            // Pinch both ends to points, like light trails converging.
            let taper = pow(max(0, 4 * u * (1 - u)), 0.85)

            // Each point shows the loudness from a moment ago: "now" lives at
            // the center, older sound rides outward toward the tips. The power
            // curve dedicates the middle third of the wave to the most recent
            // instants, so a syllable lights up a wide band immediately.
            let distance = abs(u - 0.5) * 2
            let age = pow(distance, 1.7)
            let historyIndex = max(0, lastIndex - Int(age * Double(lastIndex)))
            // Older ripples shrink as they travel out, so the wave visibly
            // relaxes the moment the speaker goes quiet.
            let ripple = levels[historyIndex] * CGFloat(1 - age * 0.45)

            let amplitude = halfHeight * strand.amp * (breathing + ripple * 0.95)
            let main = sin(2 * .pi * strand.cycles * u + phase)
            let weave = sin(2 * .pi * strand.weave * u - phase * 0.6 + strand.phase * 1.7)
            let y = midY + amplitude * CGFloat(taper * (main * 0.78 + weave * 0.22))
            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
            x += step
        }
        return path
    }
}

/// Live transcription as a polished subtitle: white text on the same dark
/// blur used by the feedback pill, so the two read as a matched set.
private struct PreviewLabel: View {
    var text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.95))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: 560)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(VisualEffectBackground().clipShape(shape))
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

