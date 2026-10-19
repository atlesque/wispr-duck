import Foundation

/// A deduplicated audio app for the UI, grouped by root app bundle ID.
struct AudioApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

struct DuckingConfiguration: Equatable {
    let bundleIDs: Set<String>
    let duckAll: Bool
    let level: Float
}

/// All methods and callbacks run on the coordinator's serial audio queue.
protocol AudioBackend: AnyObject {
    func startMonitoring(
        onAppsChanged: @escaping ([AudioApp], [AudioApp]) -> Void,
        onError: @escaping (String) -> Void
    )
    func duck(bundleIDs: Set<String>, duckAll: Bool, duckLevel: Float) -> Bool
    func restoreAll()
    func restoreAllWithFade()
    func requestSystemAudioPermissionPrompt() -> String?
    func shutdown()
}

/// Main-thread interface to the audio engine. Never waits for Core Audio.
/// The backend, its listeners, and delayed cleanup share one serial queue.
final class AudioCoordinator {
    private let queue = DispatchQueue(label: "com.wisprduck.audio", qos: .userInitiated)
    private let backend: AudioBackend
    private var configuration: DuckingConfiguration?
    private var generation = 0
    private var isReconciling = false
    private var needsReconciliation = false
    private var isShuttingDown = false
    private var onDuckingChanged: ((Bool) -> Void)?

    init(makeBackend: (DispatchQueue) -> AudioBackend) {
        backend = makeBackend(queue)
    }

    func start(
        onAppsChanged: @escaping ([AudioApp], [AudioApp]) -> Void,
        onError: @escaping (String) -> Void,
        onDuckingChanged: @escaping (Bool) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.onDuckingChanged = onDuckingChanged
        queue.async { [backend] in
            backend.startMonitoring { apps, triggerApps in
                DispatchQueue.main.async { onAppsChanged(apps, triggerApps) }
            } onError: { message in
                DispatchQueue.main.async { onError(message) }
            }
        }
    }

    func updateDucking(_ configuration: DuckingConfiguration) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isShuttingDown else { return }
        if self.configuration != configuration {
            generation += 1
            self.configuration = configuration
        }
        // Keep at most one reconciliation in flight and one refresh pending.
        needsReconciliation = true
        reconcileIfNeeded()
    }

    private func reconcileIfNeeded() {
        guard !isReconciling, needsReconciliation, let configuration else { return }
        needsReconciliation = false
        isReconciling = true
        let generation = generation
        queue.async { [backend, weak self] in
            let hasTaps = backend.duck(
                bundleIDs: configuration.bundleIDs,
                duckAll: configuration.duckAll,
                duckLevel: configuration.level
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReconciling = false
                // A restore or newer setting may have arrived while Core Audio
                // was blocked. Never publish a result from the older request.
                if self.generation == generation, !self.isShuttingDown {
                    self.onDuckingChanged?(hasTaps)
                }
                self.reconcileIfNeeded()
            }
        }
    }

    func restore(fade: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isShuttingDown else { return }
        generation += 1
        configuration = nil
        needsReconciliation = false
        onDuckingChanged?(false)
        queue.async { [backend] in
            if fade {
                backend.restoreAllWithFade()
            } else {
                backend.restoreAll()
            }
        }
    }

    func requestSystemAudioPermissionPrompt(completion: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isShuttingDown else { return }
        queue.async { [backend] in
            let message = backend.requestSystemAudioPermissionPrompt()
            DispatchQueue.main.async { completion(message) }
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        isShuttingDown = true
        generation += 1
        configuration = nil
        needsReconciliation = false
        onDuckingChanged?(false)
        queue.async { [backend] in
            backend.shutdown()
            DispatchQueue.main.async(execute: completion)
        }
    }

    deinit {
        // Also release the backend on its queue: its deinitializer cleans up
        // audio resources and must never make the UI wait.
        queue.async { [backend] in backend.shutdown() }
    }
}
