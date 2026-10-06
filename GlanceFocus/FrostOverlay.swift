import AppKit
import QuartzCore

/// "Frosted glass": blurs every screen you're not looking at, like a frozen window.
/// One transparent window is created per display. The windows stay open and only their
/// alpha changes, so freezing and thawing animate smoothly.
final class FrostOverlay {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    private let freezeDuration = 0.45   // freeze animation (s)
    private let thawDuration = 0.18     // thaw animation, faster so you never wait

    /// Recreates the windows when the display setup changes
    func rebuild(displayIDs: [CGDirectDisplayID]) {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        for id in displayIDs {
            guard let screen = Self.screen(for: id) else { continue }
            windows[id] = Self.makeWindow(for: screen)
        }
    }

    /// Keeps this display clear and frosts all the others
    func focus(on id: CGDirectDisplayID) {
        for (displayID, window) in windows {
            animate(window, to: displayID == id ? 0 : 1)
        }
    }

    /// Thaws every display (when paused, calibrating, or locked)
    func hideAll() {
        for window in windows.values {
            animate(window, to: 0)
        }
    }

    // MARK: - Helpers

    private func animate(_ window: NSWindow, to alpha: CGFloat) {
        guard window.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? freezeDuration : thawDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = alpha
        }
    }

    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private static func makeWindow(for screen: NSScreen) -> NSWindow {
        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // clicks pass through to the apps underneath
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.alphaValue = 0

        // 1) Main effect: blur everything behind the window
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.autoresizingMask = [.width, .height]
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active

        // 2) Frost layer: clearer in the middle, whiter at the edges, like rime on a cold window
        let frost = NSView(frame: blur.bounds)
        frost.autoresizingMask = [.width, .height]
        frost.wantsLayer = true
        let rime = CAGradientLayer()
        rime.type = .radial
        rime.frame = CGRect(origin: .zero, size: frame.size)
        rime.colors = [
            NSColor(calibratedWhite: 1, alpha: 0.06).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0.14).cgColor,
            NSColor(calibratedRed: 0.86, green: 0.93, blue: 1, alpha: 0.38).cgColor
        ]
        rime.locations = [0, 0.55, 1]
        rime.startPoint = CGPoint(x: 0.5, y: 0.5)
        rime.endPoint = CGPoint(x: 1.15, y: 1.15)
        frost.layer?.addSublayer(rime)
        blur.addSubview(frost)

        // 3) A small snowflake in the center
        let flake = NSTextField(labelWithString: "❄︎")
        flake.font = .systemFont(ofSize: 72, weight: .ultraLight)
        flake.textColor = NSColor.white.withAlphaComponent(0.6)
        flake.sizeToFit()
        flake.frame.origin = NSPoint(x: (frame.width - flake.frame.width) / 2,
                                     y: (frame.height - flake.frame.height) / 2)
        flake.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        blur.addSubview(flake)

        window.contentView = blur
        window.orderFrontRegardless()
        return window
    }
}
