import SwiftUI
import ServiceManagement
import Combine

@main
struct GlanceFocusApp: App {
    @StateObject private var controller = FocusController()

    var body: some Scene {
        // Dock'da ko'rinmaydi, faqat yuqoridagi menu bar'da ko'z belgisi turadi
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

        Toggle("Yoqilgan", isOn: $controller.isEnabled)

        Button("Kalibrlash…") { controller.startCalibration() }
            .disabled(controller.isCalibrating)

        Picker("Tezlik", selection: $controller.speed) {
            ForEach(Speed.allCases) { speed in
                Text(speed.title).tag(speed)
            }
        }

        Toggle("Oxirgi joyga qaytish (markaz o'rniga)", isOn: $controller.rememberPosition)

        Toggle("Kompyuter yonganda avtomatik ishga tushsin", isOn: $launchAtLogin)
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

        Button("Chiqish") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
