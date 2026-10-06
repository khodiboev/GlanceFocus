import AppKit
import SwiftUI
import Combine

/// Kalibratsiya paytida tanlangan monitorni qoraytirib, markazda qizil nuqta ko'rsatadi.
final class CalibrationOverlay {
    private var window: NSWindow?
    private let model = OverlayModel()

    init(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }

        let w = NSWindow(contentRect: screen.frame,
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false)
        w.setFrame(screen.frame, display: true)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: OverlayView(model: model))
        w.orderFrontRegardless()
        window = w
    }

    func setText(_ text: String) {
        model.text = text
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

final class OverlayModel: ObservableObject {
    @Published var text = ""
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red)
                .frame(width: 28, height: 28)
                .shadow(color: .red, radius: 12)

            Text(model.text)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .offset(y: 100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
