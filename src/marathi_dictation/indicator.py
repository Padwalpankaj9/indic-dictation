from __future__ import annotations

import math

import objc
from AppKit import (
    NSBackingStoreBuffered,
    NSBezierPath,
    NSColor,
    NSFloatingWindowLevel,
    NSMakeRect,
    NSScreen,
    NSView,
    NSWindow,
    NSWindowStyleMaskBorderless,
)
from Foundation import NSObject


class IndicatorView(NSView):
    def initWithFrame_(self, frame):  # noqa: ANN001
        self = objc.super(IndicatorView, self).initWithFrame_(frame)
        if self is None:
            return None
        self.state = "recording"
        self.phase = 0.0
        return self

    def setState_(self, state: str) -> None:
        self.state = state
        self.setNeedsDisplay_(True)

    def setPhase_(self, phase: float) -> None:
        self.phase = phase
        self.setNeedsDisplay_(True)

    def drawRect_(self, rect):  # noqa: ANN001
        bounds = self.bounds()
        pill = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(bounds, 11, 11)
        NSColor.colorWithCalibratedWhite_alpha_(0.06, 0.82).setFill()
        pill.fill()

        stroke = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(1, 1, bounds.size.width - 2, bounds.size.height - 2),
            10,
            10,
        )
        NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.32).setStroke()
        stroke.setLineWidth_(1.0)
        stroke.stroke()

        if self.state == "processing":
            self._draw_processing(bounds)
        else:
            self._draw_recording(bounds)

    def _draw_recording(self, bounds) -> None:  # noqa: ANN001
        NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.92).setFill()
        center_y = bounds.size.height / 2
        bar_width = 3.0
        spacing = 5.0
        start_x = (bounds.size.width - (5 * bar_width + 4 * spacing)) / 2
        for index in range(5):
            wave = 0.5 + 0.5 * math.sin(self.phase + index * 0.9)
            height = 4 + wave * 12
            x = start_x + index * (bar_width + spacing)
            y = center_y - height / 2
            path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                NSMakeRect(x, y, bar_width, height),
                1.5,
                1.5,
            )
            path.fill()

    def _draw_processing(self, bounds) -> None:  # noqa: ANN001
        center_x = bounds.size.width / 2
        center_y = bounds.size.height / 2
        radius = 6.0
        for index in range(8):
            alpha = 0.18 + 0.82 * ((index + int(self.phase)) % 8) / 7
            NSColor.colorWithCalibratedWhite_alpha_(1.0, alpha).setFill()
            angle = (math.tau / 8) * index
            x = center_x + math.cos(angle) * radius
            y = center_y + math.sin(angle) * radius
            dot = NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(x - 1.4, y - 1.4, 2.8, 2.8))
            dot.fill()


class VoiceIndicator(NSObject):
    def init(self):  # noqa: ANN001
        self = objc.super(VoiceIndicator, self).init()
        if self is None:
            return None
        self.window = None
        self.view = None
        self.phase = 0.0
        self.visible_state = "hidden"
        self._create_window()
        return self

    def _create_window(self) -> None:
        screen = NSScreen.mainScreen()
        frame = screen.visibleFrame()
        width = 74
        height = 24
        x = frame.origin.x + (frame.size.width - width) / 2
        y = frame.origin.y + 36
        rect = NSMakeRect(x, y, width, height)

        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect,
            NSWindowStyleMaskBorderless,
            NSBackingStoreBuffered,
            False,
        )
        self.window.setLevel_(NSFloatingWindowLevel)
        self.window.setOpaque_(False)
        self.window.setBackgroundColor_(NSColor.clearColor())
        self.window.setIgnoresMouseEvents_(True)
        self.window.setCanHide_(False)

        self.view = IndicatorView.alloc().initWithFrame_(NSMakeRect(0, 0, width, height))
        self.window.setContentView_(self.view)
        self.window.orderOut_(None)

    def show_recording(self) -> None:
        self.visible_state = "recording"
        self.view.setState_("recording")
        self.window.orderFrontRegardless()

    def show_processing(self) -> None:
        self.visible_state = "processing"
        self.view.setState_("processing")
        self.window.orderFrontRegardless()

    def hide(self) -> None:
        self.visible_state = "hidden"
        self.window.orderOut_(None)

    def tick(self) -> None:
        if self.visible_state == "hidden":
            return
        if self.visible_state == "processing":
            self.phase = (self.phase + 1) % 8
        else:
            self.phase += 0.45
        self.view.setPhase_(self.phase)
