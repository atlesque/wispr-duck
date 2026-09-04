import SwiftUI

private final class WisprDuckAppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        onReopen?()
        return true
    }
}

@main
struct WisprDuckApp: App {
    @NSApplicationDelegateAdaptor(WisprDuckAppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @StateObject private var duckController: DuckController
    @Environment(\.openWindow) private var openWindow

    init() {
        let s = AppSettings()
        _settings = State(wrappedValue: s)
        _duckController = StateObject(wrappedValue: DuckController(settings: s))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(settings: settings, duckController: duckController)
        } label: {
            Image(settings.isEnabled ? "DuckFoot" : "DuckFootDimmed")
                .id(settings.isEnabled)
                .task {
                    appDelegate.onReopen = { [settings, openWindow] in
                        guard !settings.hasCompletedOnboarding else { return }
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: "welcome")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    appDelegate.onReopen?()
                }
                .accessibilityLabel("WisprDuck")
                .accessibilityValue(menuBarStatus)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome", id: "welcome") {
            WelcomeView(settings: settings, duckController: duckController)
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
    }

    private var menuBarStatus: String {
        if !settings.isEnabled { return "Disabled" }
        if duckController.isDucked { return "Ducked" }
        return "Monitoring"
    }
}
