import SwiftUI

private final class WisprDuckAppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?
    var onTerminate: ((@escaping () -> Void) -> Void)?
    private var hasRepliedToTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let onTerminate else { return .terminateNow }
        hasRepliedToTermination = false
        let finish = { [weak self] in
            guard let self, !self.hasRepliedToTermination else { return }
            self.hasRepliedToTermination = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        onTerminate(finish)
        // A stalled audio server must not trap the user in the app. Process
        // exit releases mutedWhenTapped taps even if cleanup cannot finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: finish)
        return .terminateLater
    }

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
                    appDelegate.onTerminate = { [duckController] completion in
                        duckController.prepareForTermination(completion: completion)
                    }
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
