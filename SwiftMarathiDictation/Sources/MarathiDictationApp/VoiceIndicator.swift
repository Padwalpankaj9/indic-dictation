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

    // A slim black listening pill. Keep it visually quiet so it does not compete with the text field.
    private var glyphPill: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Group {
            switch model.state {
            case .recording:
                WaveBars(meter: model.meter)
            case .processing:
                ProcessingSpinner()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .frame(minWidth: 56, minHeight: 20)
        .background(Color.black)
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 4)
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

/// Five slim bars that respond to live mic loudness without looking heavy.
private struct WaveBars: View {
    let meter: AudioLevelMeter

    private let weights: [CGFloat] = [0.5, 0.78, 1.0, 0.78, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(meter.value)
            HStack(spacing: 2.5) {
                ForEach(weights.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.94))
                        .frame(width: 1.4, height: barHeight(index, t, level))
                }
            }
            .frame(height: 10)
        }
    }

    private func barHeight(_ index: Int, _ t: TimeInterval, _ level: CGFloat) -> CGFloat {
        let base: CGFloat = 1.5
        let maxHeight: CGFloat = 8
        let idle = 0.5 + 0.5 * sin(t * 3.0 + Double(index) * 0.9)
        let energy = level * weights[index]
        let mix = max(CGFloat(idle) * 0.08, energy)
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
    }
}

private struct ProcessingSpinner: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.82)
            .stroke(
                AngularGradient(
                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.94)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .frame(width: 14, height: 14)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}
