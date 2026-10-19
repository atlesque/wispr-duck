import Foundation
import Combine

final class DuckController: ObservableObject {
    @Published private(set) var isDucked: Bool = false
    @Published private(set) var audioApps: [AudioApp] = []
    @Published private(set) var triggerEligibleApps: [AudioApp] = []
    @Published private(set) var audioStatusMessage: String?
    let micMonitor = MicMonitor()
    private let audioCoordinator = AudioCoordinator { ProcessTapManager(queue: $0) }
    private var settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private var triggerReevaluationTimer: DispatchSourceTimer?

    init(settings: AppSettings) {
        self.settings = settings
        syncTriggerSettings()

        audioCoordinator.start { [weak self] apps, triggerApps in
            self?.audioApps = apps
            self?.triggerEligibleApps = triggerApps
        } onError: { [weak self] message in
            self?.audioStatusMessage = message
        } onDuckingChanged: { [weak self] isDucked in
            self?.isDucked = isDucked
            if isDucked { self?.audioStatusMessage = nil }
        }

        // Forward nested monitor changes to views observing this controller.
        micMonitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        micMonitor.$shouldTriggerDuck
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldDuck in
                self?.handleTriggerStateChange(shouldDuck: shouldDuck)
            }
            .store(in: &cancellables)

        settings.onSettingsChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncTriggerSettings()
                guard self.settings.isEnabled else {
                    self.restoreAndStop()
                    return
                }
                self.handleTriggerStateChange(shouldDuck: self.micMonitor.shouldTriggerDuck)
                self.micMonitor.refreshTriggerState()
            }
        }
    }

    private func syncTriggerSettings() {
        micMonitor.triggerAllApps = settings.triggerAllApps
        micMonitor.triggerBundleIDs = settings.triggerBundleIDs
    }

    private func handleTriggerStateChange(shouldDuck: Bool) {
        guard settings.isEnabled else { return }
        if shouldDuck {
            startTriggerReevaluationTimer()
            reconcileDucking()
        } else {
            stopTriggerReevaluationTimer()
            audioCoordinator.restore(fade: true)
        }
    }

    private func reconcileDucking() {
        audioCoordinator.updateDucking(DuckingConfiguration(
            bundleIDs: settings.enabledBundleIDs,
            duckAll: settings.duckAllApps,
            level: Float(settings.duckLevel) / 100.0
        ))
    }

    func restoreAndStop() {
        // Taps may still be alive during a fade even when isDucked is false.
        stopTriggerReevaluationTimer()
        audioCoordinator.restore(fade: false)
    }

    func prepareForTermination(completion: @escaping () -> Void) {
        stopTriggerReevaluationTimer()
        audioCoordinator.shutdown(completion: completion)
    }

    func requestSystemAudioPermissionPrompt(completion: @escaping (String?) -> Void) {
        audioCoordinator.requestSystemAudioPermissionPrompt(completion: completion)
    }

    var currentIssueMessage: String? {
        audioStatusMessage ?? micMonitor.monitoringIssue
    }

    private func startTriggerReevaluationTimer() {
        guard triggerReevaluationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.refreshWhileTriggered() }
        triggerReevaluationTimer = timer
        timer.resume()
    }

    private func stopTriggerReevaluationTimer() {
        triggerReevaluationTimer?.cancel()
        triggerReevaluationTimer = nil
    }

    private func refreshWhileTriggered() {
        micMonitor.refreshTriggerState()
        guard settings.isEnabled, micMonitor.shouldTriggerDuck else { return }
        reconcileDucking()
    }
}
