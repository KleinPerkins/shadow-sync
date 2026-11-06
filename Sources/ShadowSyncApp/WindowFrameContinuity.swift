import AppKit

struct WindowContinuitySnapshot: Equatable {
    let frame: NSRect
    let screenFrame: NSRect
}

@MainActor
enum WindowFrameContinuity {
    static func initialRect(size: NSSize) -> NSRect {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: size)
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func capture(
        _ window: NSWindow?
    ) -> WindowContinuitySnapshot? {
        guard let window else { return nil }
        let visible = window.screen?.visibleFrame
            ?? NSScreen.screens.max {
                intersectionArea($0.visibleFrame, window.frame)
                    < intersectionArea($1.visibleFrame, window.frame)
            }?.visibleFrame
            ?? window.frame
        return WindowContinuitySnapshot(
            frame: window.frame,
            screenFrame: visible
        )
    }

    static func apply(
        _ snapshot: WindowContinuitySnapshot?,
        to window: NSWindow?
    ) {
        guard let snapshot, let window else { return }
        let screen = NSScreen.screens.first {
            $0.visibleFrame.equalTo(snapshot.screenFrame)
        } ?? NSScreen.screens.max {
            intersectionArea(
                $0.visibleFrame,
                snapshot.frame
            ) < intersectionArea(
                $1.visibleFrame,
                snapshot.frame
            )
        }
        guard let visible = screen?.visibleFrame else {
            return
        }
        let minimum = window.minSize
        let width = min(
            visible.width,
            max(minimum.width, snapshot.frame.width)
        )
        let height = min(
            visible.height,
            max(minimum.height, snapshot.frame.height)
        )
        let x = min(
            max(snapshot.frame.minX, visible.minX),
            visible.maxX - width
        )
        let y = min(
            max(snapshot.frame.minY, visible.minY),
            visible.maxY - height
        )
        window.setFrame(
            NSRect(
                x: x,
                y: y,
                width: width,
                height: height
            ),
            display: false
        )
    }

    private static func intersectionArea(
        _ lhs: NSRect,
        _ rhs: NSRect
    ) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        return overlap.isNull
            ? 0 : overlap.width * overlap.height
    }
}
