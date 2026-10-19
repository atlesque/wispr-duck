import CoreAudio
import AppKit
import os

private let logger = Logger(subsystem: "com.wisprduck", category: "ProcessTapManager")

/// Identifies an audio-producing process discovered via Core Audio.
struct AudioProcess: Identifiable, Hashable {
    let pid: pid_t
    let objectID: AudioObjectID
    let bundleID: String?
    let name: String

    var id: pid_t { pid }

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.pid == rhs.pid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }
}

/// Manages per-process audio taps for volume ducking.
/// Enumerates audio-producing processes, creates/destroys ProcessTap instances,
/// and monitors for new audio processes appearing while ducked.
/// Confined to AudioCoordinator's queue, including listeners and fade cleanup.
final class ProcessTapManager: AudioBackend {
    private var activeTaps: [pid_t: ProcessTap] = [:]
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue: DispatchQueue
    private var isDucking = false
    private var currentDuckLevel: Float = 1.0
    private var currentBundleIDs: Set<String> = []
    private var duckAllMode = false
    private var fadeOutTimer: DispatchWorkItem?
    private var fadeOutGeneration = 0
    private var onProcessListChanged: (([AudioProcess]) -> Void)?
    private var onError: ((String) -> Void)?
    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var systemAudioPrimer: SystemAudioPermissionPrimer?

    private let appResolver = AppBundleIDResolver()

    init(queue: DispatchQueue) {
        listenerQueue = queue
    }

    func startMonitoring(
        onAppsChanged: @escaping ([AudioApp], [AudioApp]) -> Void,
        onError: @escaping (String) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(listenerQueue))
        self.onError = onError
        onProcessListChanged = { [weak self] processes in
            guard let self else { return }
            onAppsChanged(
                self.audioApps(from: processes),
                self.audioApps(from: processes, includeAccessory: true)
            )
        }
        startProcessListMonitoring()
        onProcessListChanged?(enumerateAudioProcesses())
    }

    // MARK: - Process Enumeration

    /// Returns all processes currently producing audio, excluding our own process.
    func enumerateAudioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get size
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        // Get process object IDs
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &objectIDs
        )
        guard status == noErr else { return [] }

        let myPID = ProcessInfo.processInfo.processIdentifier

        return objectIDs.compactMap { objectID -> AudioProcess? in
            guard let pid = pidForProcessObject(objectID), pid != myPID else { return nil }
            // The process object list also contains clients that have an audio
            // object but are not currently producing output. Tapping those
            // clients creates aggregate devices that remain uninitialized until
            // they eventually emit audio, causing repeated delayed retries.
            guard isProcessRunningOutput(objectID) else { return nil }
            let identity = appIdentityForProcessOrAncestor(pid)
            // Prefer the bundle ID reported by Core Audio. It is available at
            // HAL registration time, before NSRunningApplication necessarily
            // exposes a helper process identity.
            let bundleID = bundleIDForProcessObject(objectID) ?? identity?.bundleID
            let name = identity?.name

            return AudioProcess(pid: pid, objectID: objectID, bundleID: bundleID, name: name ?? "PID \(pid)")
        }
    }

    /// Returns deduplicated apps grouped by root app bundle ID.
    /// "Google Chrome Helper (Renderer)" groups under "Google Chrome".
    ///
    /// - Parameter includeAccessory: When true, includes menu-bar-only apps
    ///   (e.g., Wispr Flow) alongside regular apps. When false, only apps with
    ///   a Dock icon are returned. System daemons and XPC services are always excluded.
    func audioApps(from processes: [AudioProcess], includeAccessory: Bool = false) -> [AudioApp] {
        var seen = Set<String>()
        var apps: [AudioApp] = []

        for process in processes {
            guard let bid = process.bundleID else { continue }
            let rootBID = appResolver.rootAppBundleID(for: bid)
            guard !seen.contains(rootBID) else { continue }
            seen.insert(rootBID)

            let rootApp = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == rootBID
            }
            if includeAccessory {
                // Include regular apps and menu-bar accessories, exclude background daemons
                guard let policy = rootApp?.activationPolicy,
                      policy == .regular || policy == .accessory else { continue }
            } else {
                // Only show regular apps (Dock icon / real UI)
                guard rootApp?.activationPolicy == .regular else { continue }
            }

            let name = rootApp?.localizedName ?? process.name
            apps.append(AudioApp(bundleID: rootBID, name: name))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Check if a process's bundle ID matches any of the selected bundle IDs,
    /// resolving helpers to their parent app.
    private func processMatchesSelection(_ process: AudioProcess, selectedBundleIDs: Set<String>) -> Bool {
        guard let bid = process.bundleID else { return false }
        let rootBID = appResolver.rootAppBundleID(for: bid)
        return selectedBundleIDs.contains(rootBID)
    }

    // MARK: - Duck / Restore

    /// Duck audio for processes matching the given bundle IDs.
    /// If bundleIDs is empty and duckAll is true, ducks all audio processes.
    /// If called during a fade-out, cancels the fade and reuses existing taps.
    @discardableResult
    func duck(bundleIDs: Set<String>, duckAll: Bool, duckLevel: Float) -> Bool {
        dispatchPrecondition(condition: .onQueue(listenerQueue))
        // Cancel any pending fade-out destruction
        fadeOutTimer?.cancel()
        fadeOutTimer = nil
        fadeOutGeneration += 1

        guard let outputUID = getDefaultOutputDeviceUID() else {
            reportError("WisprDuck could not read the current output device. Check macOS audio output and permissions.")
            return false
        }

        isDucking = true
        currentDuckLevel = duckLevel
        currentBundleIDs = bundleIDs
        duckAllMode = duckAll
        startOutputDeviceMonitoring()

        return reconcileActiveTaps(
            bundleIDs: bundleIDs,
            duckAll: duckAll,
            duckLevel: duckLevel,
            outputDeviceUID: outputUID
        )
    }

    @discardableResult
    private func reconcileActiveTaps(
        bundleIDs: Set<String>,
        duckAll: Bool,
        duckLevel: Float,
        outputDeviceUID: String
    ) -> Bool {
        let processes = enumerateAudioProcesses()
        let processesByPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        for pid in Array(activeTaps.keys) {
            guard let tap = activeTaps[pid] else { continue }
            guard let process = processesByPID[pid] else {
                tap.stop()
                activeTaps.removeValue(forKey: pid)
                continue
            }

            let shouldDuck = duckAll || processMatchesSelection(process, selectedBundleIDs: bundleIDs)
            if shouldDuck {
                tap.updateDuckLevel(duckLevel)
            } else {
                tap.stop()
                activeTaps.removeValue(forKey: pid)
            }
        }

        let toDuck = processes.filter { process in
            guard activeTaps[process.pid] == nil else { return false }
            if duckAll { return true }
            return processMatchesSelection(process, selectedBundleIDs: bundleIDs)
        }

        for process in toDuck {
            let tap = ProcessTap(
                processObjectID: process.objectID,
                pid: process.pid
            )
            if tap.start(outputDeviceUID: outputDeviceUID, duckLevel: duckLevel) {
                activeTaps[process.pid] = tap
            } else {
                reportError(
                    tap.lastError
                    ?? "WisprDuck could not start system audio capture. Grant Screen & System Audio Recording permission."
                )
            }
        }

        return !activeTaps.isEmpty
    }

    /// Restore all ducked processes immediately. Used for app quit where
    /// we can't wait for a fade.
    func restoreAll() {
        dispatchPrecondition(condition: .onQueue(listenerQueue))
        isDucking = false
        fadeOutTimer?.cancel()
        fadeOutTimer = nil
        fadeOutGeneration += 1

        for tap in activeTaps.values {
            tap.stop()
        }
        activeTaps.removeAll()
        stopOutputDeviceMonitoring()
    }

    /// Smoothly restore audio by ramping volume back to 1.0 before destroying taps.
    /// Taps stay in activeTaps during the fade so duck() can cancel and reuse them.
    /// Timer fires just before the ramp completes so the tap destruction pop lands at 100%.
    func restoreAllWithFade() {
        dispatchPrecondition(condition: .onQueue(listenerQueue))
        isDucking = false
        fadeOutTimer?.cancel()
        fadeOutGeneration += 1
        let generation = fadeOutGeneration

        guard !activeTaps.isEmpty else {
            fadeOutTimer?.cancel()
            fadeOutTimer = nil
            stopOutputDeviceMonitoring()
            return
        }

        // Calculate how long the ramp will actually take based on current duck level.
        // The linear ramp in ProcessTap sweeps 0→1 in 1s, so a partial sweep from
        // currentDuckLevel→1.0 takes (1 - currentDuckLevel) * 1.0 seconds.
        // Wait for the ramp to finish before tearing down taps, with a small scheduling cushion.
        let rampDuration: Double = 1.0
        let estimatedFadeTime = max(0.05, Double(1.0 - currentDuckLevel) * rampDuration + 0.05)

        // Ramp all taps toward full volume
        for tap in activeTaps.values {
            tap.updateDuckLevel(1.0)
        }

        // Schedule tap destruction just after the linear ramp completes.
        // If duck() is called before this fires, it cancels the timer and reuses the taps.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isDucking, self.fadeOutGeneration == generation else { return }
            for tap in self.activeTaps.values {
                tap.stop()
            }
            self.activeTaps.removeAll()
            self.fadeOutTimer = nil
            self.stopOutputDeviceMonitoring()
        }
        fadeOutTimer = workItem
        listenerQueue.asyncAfter(deadline: .now() + estimatedFadeTime, execute: workItem)
    }

    // MARK: - Process List Monitoring

    /// Start monitoring the audio process list. Always-on for UI updates;
    /// also creates/removes taps dynamically while ducking is active.
    func startProcessListMonitoring() {
        guard processListListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        processListListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Enumeration and tap lifecycle share the audio queue. Only the
            // resulting app snapshots are forwarded to the UI.
            let processes = self.enumerateAudioProcesses()
            self.handleProcessListChanged(with: processes)
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            processListListenerBlock!
        )
        guard status == noErr else {
            logger.error("Could not monitor audio process list: \(describeOSStatus(status))")
            processListListenerBlock = nil
            return
        }
    }

    private func stopProcessListMonitoring() {
        guard let block = processListListenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        if status != noErr {
            logger.error("Could not stop monitoring audio process list: \(describeOSStatus(status))")
        }
        processListListenerBlock = nil
    }

    // MARK: - Output Device Monitoring

    private func startOutputDeviceMonitoring() {
        guard outputDeviceListenerBlock == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        outputDeviceListenerBlock = { [weak self] _, _ in
            self?.handleOutputDeviceChanged()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            outputDeviceListenerBlock!
        )
        guard status == noErr else {
            logger.error("Could not monitor default output device: \(describeOSStatus(status))")
            outputDeviceListenerBlock = nil
            return
        }
    }

    private func stopOutputDeviceMonitoring() {
        guard let block = outputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        if status != noErr {
            logger.error("Could not stop monitoring default output device: \(describeOSStatus(status))")
        }
        outputDeviceListenerBlock = nil
    }

    private func handleOutputDeviceChanged() {
        guard isDucking else { return }
        let bundleIDs = currentBundleIDs
        let duckAll = duckAllMode
        let level = currentDuckLevel
        restoreAll()
        _ = duck(bundleIDs: bundleIDs, duckAll: duckAll, duckLevel: level)
    }

    private func handleProcessListChanged(with processes: [AudioProcess]) {
        // Always notify UI so the app list stays current
        onProcessListChanged?(processes)

        // Only manage taps while actively ducking
        guard isDucking else { return }

        guard let outputUID = getDefaultOutputDeviceUID() else {
            reportError("WisprDuck could not read the current output device. Check macOS audio output and permissions.")
            return
        }

        // Create taps for new matching processes
        let toDuck = processes.filter { process in
            guard activeTaps[process.pid] == nil else { return false }
            if duckAllMode { return true }
            return processMatchesSelection(process, selectedBundleIDs: currentBundleIDs)
        }

        for process in toDuck {
            let tap = ProcessTap(
                processObjectID: process.objectID,
                pid: process.pid
            )
            if tap.start(outputDeviceUID: outputUID, duckLevel: currentDuckLevel) {
                activeTaps[process.pid] = tap
            } else {
                reportError(
                    tap.lastError
                    ?? "WisprDuck could not start system audio capture. Grant Screen & System Audio Recording permission."
                )
            }
        }

        // Clean up taps for processes that have stopped producing audio
        let activePIDs = Set(processes.map(\.pid))
        let stalePIDs = activeTaps.keys.filter { !activePIDs.contains($0) }
        for pid in stalePIDs {
            activeTaps[pid]?.stop()
            activeTaps.removeValue(forKey: pid)
        }
    }

    /// Attempts to trigger macOS' System Audio Recording prompt during onboarding.
    /// macOS shows this prompt when recording starts from an aggregate device that contains a tap.
    func requestSystemAudioPermissionPrompt() -> String? {
        dispatchPrecondition(condition: .onQueue(listenerQueue))
        guard systemAudioPrimer == nil else { return nil }
        guard let outputUID = getDefaultOutputDeviceUID() else {
            return "WisprDuck could not read the current output device. Open System Audio settings and allow WisprDuck."
        }

        let primer = SystemAudioPermissionPrimer()
        guard primer.start(outputDeviceUID: outputUID) else {
            return primer.lastError ?? "WisprDuck could not start a system audio permission request."
        }

        systemAudioPrimer = primer
        listenerQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.systemAudioPrimer?.stop()
            self?.systemAudioPrimer = nil
        }

        return nil
    }

    // MARK: - Output Device Helpers

    private func getDefaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.error("Could not get default output device: \(describeOSStatus(status))")
            return nil
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
        guard status == noErr, let uid else {
            logger.error("Could not get default output device UID: \(describeOSStatus(status))")
            return nil
        }
        return uid.takeRetainedValue() as String
    }

    private func reportError(_ message: String) {
        logger.error("\(message)")
        onError?(message)
    }

    func shutdown() {
        dispatchPrecondition(condition: .onQueue(listenerQueue))
        stopProcessListMonitoring()
        stopOutputDeviceMonitoring()
        systemAudioPrimer?.stop()
        systemAudioPrimer = nil
        restoreAll()
    }

    deinit {
        shutdown()
    }
}

/// A short-lived, unmuted Core Audio tap used only to trigger the system-audio
/// recording permission prompt during onboarding.
private final class SystemAudioPermissionPrimer {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let tapUUID = UUID()
    private let aggregateUUID = UUID()
    private let ioQueue = DispatchQueue(label: "com.wisprduck.systemaudioprimer", qos: .userInitiated)
    private(set) var lastError: String?

    func start(outputDeviceUID: String) -> Bool {
        lastError = nil

        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [AudioObjectID]())
        tapDesc.uuid = tapUUID
        tapDesc.name = "WisprDuck Permission Check"
        tapDesc.muteBehavior = .unmuted
        tapDesc.isPrivate = true

        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr else {
            lastError = "Could not create a system audio permission tap: \(describeOSStatus(status))"
            logger.error("\(self.lastError ?? "Unknown system audio permission tap error")")
            return false
        }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WisprDuck Permission Check",
            kAudioAggregateDeviceUIDKey: aggregateUUID.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputDeviceUID,
                    kAudioSubDeviceDriftCompensationKey: false,
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
        guard status == noErr else {
            lastError = "Could not create a system audio permission device: \(describeOSStatus(status))"
            logger.error("\(self.lastError ?? "Unknown system audio permission device error")")
            cleanupTap()
            return false
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, ioQueue) { _, _, _, outOutputData, _ in
            let outputs = UnsafeMutableAudioBufferListPointer(outOutputData)
            for output in outputs {
                if let data = output.mData {
                    memset(data, 0, Int(output.mDataByteSize))
                }
            }
        }
        guard status == noErr else {
            lastError = "Could not create a system audio permission callback: \(describeOSStatus(status))"
            logger.error("\(self.lastError ?? "Unknown system audio permission callback error")")
            cleanupAggregateDevice()
            cleanupTap()
            return false
        }

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else {
            lastError = "Could not start the system audio permission request: \(describeOSStatus(status))"
            logger.error("\(self.lastError ?? "Unknown system audio permission start error")")
            cleanupIOProc()
            cleanupAggregateDevice()
            cleanupTap()
            return false
        }

        return true
    }

    func stop() {
        if let ioProcID {
            let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if status != noErr {
                logger.error("Could not stop system audio permission primer: \(describeOSStatus(status))")
            }
        }
        cleanupIOProc()
        cleanupAggregateDevice()
        cleanupTap()
    }

    private func cleanupIOProc() {
        guard let ioProcID else { return }
        let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        if status != noErr {
            logger.error("Could not destroy system audio permission callback: \(describeOSStatus(status))")
        }
        self.ioProcID = nil
    }

    private func cleanupAggregateDevice() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if status != noErr {
            logger.error("Could not destroy system audio permission device: \(describeOSStatus(status))")
        }
        aggregateDeviceID = kAudioObjectUnknown
    }

    private func cleanupTap() {
        guard tapID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            logger.error("Could not destroy system audio permission tap: \(describeOSStatus(status))")
        }
        tapID = kAudioObjectUnknown
    }
}
