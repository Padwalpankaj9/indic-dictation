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

    // A larger glass pill makes the listening state obvious without showing extra text.
    private var glyphPill: some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        return HStack(spacing: 6.5) {
            MicBadge()

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1, height: 19)

            Group {
                switch model.state {
                case .recording:
                    WaveBars(meter: model.meter)
                case .processing:
                    HStack {
                        Spacer(minLength: 0)
                        ProcessingSpinner()
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, 6.5)
        .padding(.trailing, 10.5)
        .frame(width: 216, height: 34)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.98), Color(red: 0.08, green: 0.08, blue: 0.08).opacity(0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(shape)
        )
        .overlay(
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
        .overlay(
            shape
                .strokeBorder(Color.black.opacity(0.9), lineWidth: 1)
                .padding(1)
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.32), radius: 9, x: 0, y: 3)
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

private struct MicBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
            Circle()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.9)
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
        .frame(width: 26, height: 26)
    }
}

/// A compact waveform with travelling motion, so speech feels alive instead of
/// just scaling a fixed row of bars.
private struct WaveBars: View {
    let meter: AudioLevelMeter

    private let weights: [CGFloat] = [
        0.20, 0.32, 0.52, 0.76, 0.64, 0.38,
        0.28, 0.58, 0.90, 0.74, 0.48, 0.34,
        0.46, 0.82, 1.00, 0.88, 0.62, 0.40,
        0.34, 0.68, 0.96, 0.78, 0.54, 0.36,
        0.26, 0.50, 0.72, 0.56, 0.40, 0.28,
        0.22, 0.18
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(meter.value)
            HStack(spacing: 2.15) {
                ForEach(weights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(barOpacity(index, t, level)))
                        .frame(width: 1.35, height: barHeight(index, t, level))
                        .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.74), value: level)
                }
            }
            .frame(width: 142, height: 22)
        }
    }

    private func barHeight(_ index: Int, _ t: TimeInterval, _ level: CGFloat) -> CGFloat {
        let base: CGFloat = 2.2
        let maxHeight: CGFloat = 19.5
        let voice = min(1, pow(max(level, 0.001) * 2.9, 0.68))
        let indexPhase = Double(index) * 0.58
        let travel = 0.5 + 0.5 * sin(t * (5.8 + Double(voice) * 3.4) - indexPhase)
        let shimmer = 0.5 + 0.5 * sin(t * 11.0 + Double(index) * 1.37)
        let idle = 0.08 + 0.10 * CGFloat(travel)
        let spoken = voice * weights[index] * (0.54 + 0.34 * CGFloat(travel) + 0.12 * CGFloat(shimmer))
        let edgeFade = min(1, CGFloat(min(index + 2, weights.count - index + 1)) / 6)
        return base + min(1, idle + spoken) * maxHeight * edgeFade
    }

    private func barOpacity(_ index: Int, _ t: TimeInterval, _ level: CGFloat) -> CGFloat {
        let edgeFade = min(1, CGFloat(min(index + 3, weights.count - index + 2)) / 8)
        let pulse = 0.5 + 0.5 * sin(t * 4.6 - Double(index) * 0.42)
        return min(1, 0.42 + edgeFade * 0.36 + min(1, level * 2.4) * 0.18 + CGFloat(pulse) * 0.08)
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

private struct ProcessingSpinner: View {
    @State private var spin = false

    var body: some View {
        HStack(spacing: 20) {
            Circle()
                .trim(from: 0, to: 0.82)
                .stroke(
                    AngularGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.96)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .frame(width: 15, height: 15)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .onAppear {
                    withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                        spin = true
                    }
                }

            Text("Finalizing")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(width: 142, height: 22)
    }
}
