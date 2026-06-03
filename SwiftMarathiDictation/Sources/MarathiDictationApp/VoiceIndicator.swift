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

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let width = min(screen.width - 64, 720)
        let height: CGFloat = 220
        let rect = NSRect(
            x: screen.midX - width / 2,
            y: screen.minY,
            width: width,
            height: height
        )

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
        window.orderFrontRegardless()
    }

    func showProcessing() {
        // Keep the text visible through finalizing so it never blinks away.
        model.state = .processing
        window.orderFrontRegardless()
    }

    func setPreview(_ text: String) {
        // Ignore empty interims so the line stays put instead of flickering.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.previewText = String(text.suffix(260))
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

    // The feedback bar in its dark blur pill, unchanged from the version that worked.
    private var glyphPill: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Group {
            switch model.state {
            case .recording:
                WaveBars(meter: model.meter)
            case .processing:
                ProcessingSpinner()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minWidth: 64, minHeight: 30)
        .background(VisualEffectBackground().clipShape(shape))
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.16), .clear],
                    startPoint: .top,
                    endPoint: .center
                ),
                lineWidth: 1
            )
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)
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

/// Five bars that respond to live mic loudness, with a gentle idle motion
/// so they never look frozen during silence.
private struct WaveBars: View {
    let meter: AudioLevelMeter

    private let weights: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(meter.value)
            HStack(spacing: 3) {
                ForEach(weights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: 2, height: barHeight(index, t, level))
                }
            }
            .frame(height: 16)
        }
    }

    private func barHeight(_ index: Int, _ t: TimeInterval, _ level: CGFloat) -> CGFloat {
        let base: CGFloat = 2.5
        let maxHeight: CGFloat = 14
        let idle = 0.5 + 0.5 * sin(t * 3.0 + Double(index) * 0.9)
        let energy = level * weights[index]
        let mix = max(CGFloat(idle) * 0.16, energy)
        return base + mix * maxHeight
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
            .animation(.easeOut(duration: 0.18), value: text)
    }
}

private struct ProcessingSpinner: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.82)
            .stroke(
                AngularGradient(
                    colors: [Color.white.opacity(0.12), Color.white.opacity(0.95)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
            )
            .frame(width: 15, height: 15)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .frame(width: 18, height: 18)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}
