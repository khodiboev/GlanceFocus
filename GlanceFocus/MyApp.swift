import SwiftUI
import ServiceManagement
import Combine

@main
struct GlanceFocusApp: App {
    @StateObject private var controller = FocusController()

    var body: some Scene {
        // No Dock icon: the app lives in the menu bar as an eye icon
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.isEnabled ? "eye" : "eye.slash")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var controller: FocusController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(controller.statusText)

        Divider()

        Toggle("Enabled", isOn: $controller.isEnabled)

        Button("Calibrate…") { controller.startCalibration() }
            .disabled(controller.isCalibrating)

        Picker("Speed", selection: $controller.speed) {
            ForEach(Speed.allCases) { speed in
                Text(speed.title).tag(speed)
            }
        }

        Divider()

        Toggle("Move cursor", isOn: $controller.moveCursor)
        Toggle("Frosted glass ❄️", isOn: $controller.frostEnabled)
        Toggle("Return to last cursor position", isOn: $controller.rememberPosition)
            .disabled(!controller.moveCursor)

        Divider()

        Toggle("Launch at login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

        Divider()

        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
