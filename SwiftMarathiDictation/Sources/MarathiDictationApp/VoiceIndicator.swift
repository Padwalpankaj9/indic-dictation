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

    init() {
        model = IndicatorModel(meter: meter)

        let rect = Self.windowFrame(for: Self.targetScreen())

        let hosting = NSHostingView(rootView: IndicatorRoot(model: model))
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        hosting.autoresizingMask = [.width, .height]

        window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = hosting
    }

    func showRecording() {
        // Note: does NOT touch the text. START_SPEECH calls this repeatedly,
        // and clearing here is what made the preview flicker.
        model.state = .recording
        moveToActiveScreen()
        window.orderFrontRegardless()
    }

    func showProcessing() {
        // Keep the text visible through finalizing so it never blinks away.
        model.state = .processing
        moveToActiveScreen()
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
    }

    private func moveToActiveScreen() {
        window.setFrame(Self.windowFrame(for: Self.targetScreen()), display: true)
    }

    private static func targetScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        return NSScreen.screens.min { lhs, rhs in
            distanceSquared(from: mouseLocation, to: lhs.frame) < distanceSquared(from: mouseLocation, to: rhs.frame)
        } ?? NSScreen.main!
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
        .padding(.bottom, 36)
    }

    // A larger glass pill makes the listening state obvious without showing extra text.
    private var glyphPill: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return HStack(spacing: 14) {
            MicBadge()

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 28)

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
        .padding(.leading, 9)
        .padding(.trailing, 18)
        .frame(width: 330, height: 58)
        .background(VisualEffectBackground().clipShape(shape))
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.94), Color.black.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(shape)
        )
        .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .overlay(
            shape
                .strokeBorder(Color.black.opacity(0.9), lineWidth: 1)
                .padding(1)
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.42), radius: 18, x: 0, y: 8)
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
                .fill(Color.white.opacity(0.08))
            Circle()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            Image(systemName: "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
        .frame(width: 42, height: 42)
    }
}

/// A wider waveform that responds to live mic loudness and reads clearly at a glance.
private struct WaveBars: View {
    let meter: AudioLevelMeter

    private let weights: [CGFloat] = [
        0.16, 0.24, 0.38, 0.58, 0.74, 0.48,
        0.32, 0.66, 0.92, 0.72, 0.44, 0.30,
        0.54, 0.84, 1.00, 0.86, 0.60, 0.36,
        0.42, 0.70, 0.96, 0.78, 0.52, 0.30,
        0.24, 0.46, 0.68, 0.50, 0.34, 0.22,
        0.16, 0.12
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(meter.value)
            HStack(spacing: 3.4) {
                ForEach(weights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(barOpacity(index, level)))
                        .frame(width: 1.6, height: barHeight(index, t, level))
                }
            }
            .frame(width: 210, height: 34)
        }
    }

    private func barHeight(_ index: Int, _ t: TimeInterval, _ level: CGFloat) -> CGFloat {
        let base: CGFloat = 3.0
        let maxHeight: CGFloat = 26
        let idle = 0.5 + 0.5 * sin(t * 3.8 + Double(index) * 0.64)
        let energy = level * weights[index]
        let mix = max(CGFloat(idle) * 0.05, energy)
        return base + mix * maxHeight
    }

    private func barOpacity(_ index: Int, _ level: CGFloat) -> CGFloat {
        let edgeFade = min(1, CGFloat(min(index + 3, weights.count - index + 2)) / 8)
        return min(1, 0.38 + edgeFade * 0.42 + level * 0.25)
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
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 120, height: 1)

            Circle()
                .trim(from: 0, to: 0.82)
                .stroke(
                    AngularGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.96)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .onAppear {
                    withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                        spin = true
                    }
                }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 22, height: 1)
        }
        .frame(width: 210, height: 34)
    }
}
