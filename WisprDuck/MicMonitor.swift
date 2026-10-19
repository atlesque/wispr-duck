import CoreAudio
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.wisprduck", category: "MicMonitor")

final class MicMonitor: ObservableObject {
    // Ensure NSMicrophoneUsageDescription is present if the app requests mic access.
    @Published private(set) var isMicActive: Bool = false
    @Published private(set) var shouldTriggerDuck: Bool = false
    @Published private(set) var monitoringIssue: String?

    /// When true, any app using the mic triggers ducking.
    var triggerAllApps: Bool = true {
        didSet { triggerSettingsDidChange() }
    }

    /// Bundle IDs that should trigger ducking when using the mic.
    var triggerBundleIDs: Set<String> = [] {
        didSet { triggerSettingsDidChange() }
    }

    private let appResolver = AppBundleIDResolver()

    private var currentDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    private var perProcessListenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let listenerQueue = DispatchQueue(label: "com.wisprduck.micmonitor", qos: .userInitiated)
    private let listenerQueueKey = DispatchSpecificKey<Void>()

    init() {
        listenerQueue.setSpecific(key: listenerQueueKey, value: ())
        // Core Audio can stall even during listener setup. Launch must leave
        // the main thread free to display and open the menu bar item.
        listenerQueue.async { [self] in
            self.setupDefaultDeviceListener()
            self.setupProcessListListener()
            self.bindToCurrentInputDevice()
            self.refreshPerProcessListeners()
        }
    }

    // deinit calls performOnListenerQueue which may block via sync. This is safe
    // because MicMonitor is owned by DuckController (a @StateObject released on
    // the main thread, never on the listener queue). If ownership changes, audit
    // for potential deadlock.
    deinit {
        performOnListenerQueue {
            removeDeviceListener()
            removeDefaultDeviceListener()
            removeProcessListListener()
            removeAllPerProcessListeners()
        }
    }

    private func performOnListenerQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: listenerQueueKey) != nil {
            work()
        } else {
            listenerQueue.sync(execute: work)
        }
    }

    // MARK: - Default Input Device Change Monitoring

    private func setupDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        defaultDeviceListenerBlock = { [weak self] _, _ in
            self?.bindToCurrentInputDevice()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            defaultDeviceListenerBlock!
        )
        guard status == noErr else {
            reportIssue("WisprDuck could not monitor the default microphone: \(describeOSStatus(status))")
            defaultDeviceListenerBlock = nil
            return
        }
        clearIssue()
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
            logger.error("Could not stop monitoring the default microphone: \(describeOSStatus(status))")
        }
        defaultDeviceListenerBlock = nil
    }

    // MARK: - Input Device "Is Running" Monitoring

    private func bindToCurrentInputDevice() {
        removeDeviceListener()

        guard let deviceID = getDefaultInputDevice() else {
            reportIssue("WisprDuck could not find a default microphone. Choose an input device in System Settings.")
            DispatchQueue.main.async {
                self.isMicActive = false
                self.shouldTriggerDuck = false
            }
            return
        }

        currentDeviceID = deviceID
        updateMicStatus()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        deviceListenerBlock = { [weak self] _, _ in
            self?.updateMicStatus()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            currentDeviceID,
            &address,
            listenerQueue,
            deviceListenerBlock!
        )
        guard status == noErr else {
            reportIssue("WisprDuck could not monitor microphone activity: \(describeOSStatus(status))")
            deviceListenerBlock = nil
            return
        }
        clearIssue()
    }

    private func removeDeviceListener() {
        guard currentDeviceID != kAudioObjectUnknown, let block = deviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            currentDeviceID,
            &address,
            listenerQueue,
            block
        )
        if status != noErr {
            logger.error("Could not stop monitoring microphone activity: \(describeOSStatus(status))")
        }
        deviceListenerBlock = nil
    }

    // MARK: - Process Object List Monitoring

    private func setupProcessListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        processListListenerBlock = { [weak self] _, _ in
            self?.refreshPerProcessListeners()
            self?.reevaluateTriggerState()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            processListListenerBlock!
        )
        guard status == noErr else {
            reportIssue("WisprDuck could not monitor audio process activity: \(describeOSStatus(status))")
            processListListenerBlock = nil
            return
        }
        clearIssue()
    }

    private func removeProcessListListener() {
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
            logger.error("Could not stop monitoring audio process activity: \(describeOSStatus(status))")
        }
        processListListenerBlock = nil
    }

    // MARK: - Per-Process IsRunning Listeners

    private func refreshPerProcessListeners() {
        let objectIDs = Set(getAudioProcessObjectIDs())
        let tracked = Set(perProcessListenerBlocks.keys)

        // Remove listeners for processes that left
        for objectID in tracked.subtracting(objectIDs) {
            removePerProcessListener(objectID)
        }

        // Add listeners for new processes
        for objectID in objectIDs.subtracting(tracked) {
            addPerProcessListener(objectID)
        }
    }

    private func addPerProcessListener(_ objectID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reevaluateTriggerState()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            listenerQueue,
            block
        )

        if status == noErr {
            perProcessListenerBlocks[objectID] = block
            clearIssue()
        } else {
            reportIssue("WisprDuck could not monitor an app's microphone activity: \(describeOSStatus(status))")
        }
    }

    private func removePerProcessListener(_ objectID: AudioObjectID) {
        guard let block = perProcessListenerBlocks.removeValue(forKey: objectID) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            objectID,
            &address,
            listenerQueue,
            block
        )
        if status != noErr {
            logger.error("Could not stop monitoring app microphone activity \(objectID): \(describeOSStatus(status))")
        }
    }

    private func removeAllPerProcessListeners() {
        for objectID in Array(perProcessListenerBlocks.keys) {
            removePerProcessListener(objectID)
        }
    }

    // MARK: - Trigger Evaluation

    /// Called from didSet of trigger settings (main thread). Dispatches to the
    /// listener queue so CoreAudio reads (currentDeviceID, process state) are
    /// serialized with listener callbacks that write the same state.
    private func triggerSettingsDidChange() {
        listenerQueue.async { [weak self] in
            self?.reevaluateTriggerState()
        }
    }

    func refreshTriggerState() {
        listenerQueue.async { [weak self] in
            self?.reevaluateTriggerState()
        }
    }

    private func updateMicStatus() {
        let micActive = isDeviceRunningSomewhere()
        DispatchQueue.main.async {
            self.isMicActive = micActive
        }
        reevaluateTriggerState(micActive: micActive)
    }

    /// Central re-evaluation: checks which processes are using the mic input
    /// and whether any of them match the trigger app list.
    ///
    /// Always called on `listenerQueue` — either directly from CoreAudio listener
    /// callbacks or dispatched from `triggerSettingsDidChange()`. Reads CoreAudio
    /// state on the listener queue, then dispatches to main to read configuration
    /// and publish the result.
    private func reevaluateTriggerState(micActive: Bool? = nil) {
        // Core Audio reads and app identity lookups can block; keep them here.
        let deviceActive = micActive ?? isDeviceRunningSomewhere()

        // Gather process-level data while still on the listener queue
        let objectIDs = getAudioProcessObjectIDs()
        let myPID = ProcessInfo.processInfo.processIdentifier

        // Collect Core Audio's bundle ID first, then app-ancestry IDs as a
        // fallback/compatibility path for helper processes. Core Audio knows
        // the process identity as soon as it reports an active input stream;
        // NSRunningApplication can lag for short-lived native helpers.
        var seenInputBundleIDs = Set<String>()
        var inputBundleIDs: [String] = []
        for objectID in objectIDs {
            guard let pid = pidForProcessObject(objectID), pid != myPID else { continue }
            guard isProcessRunningInput(objectID) else { continue }

            if let bundleID = bundleIDForProcessObject(objectID),
               seenInputBundleIDs.insert(bundleID).inserted {
                inputBundleIDs.append(bundleID)
            }

            for bundleID in appBundleIDsForProcessAncestry(pid) where seenInputBundleIDs.insert(bundleID).inserted {
                inputBundleIDs.append(bundleID)
            }
        }

        let resolvedInputBundleIDs = inputBundleIDs.map { appResolver.rootAppBundleID(for: $0) }

        // Dispatch to main only to read configuration and publish the result.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isMicActive = deviceActive || !inputBundleIDs.isEmpty
            if self.triggerAllApps {
                self.shouldTriggerDuck = deviceActive || !inputBundleIDs.isEmpty
                return
            }
            let triggerIDs = self.triggerBundleIDs
            self.shouldTriggerDuck = resolvedInputBundleIDs.contains { triggerIDs.contains($0) }
        }
    }

    private func isDeviceRunningSomewhere() -> Bool {
        guard currentDeviceID != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(currentDeviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    // MARK: - Audio Process Helpers

    private func getAudioProcessObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &objectIDs
        )
        guard status == noErr else { return [] }
        return objectIDs
    }

    private func isProcessRunningInput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    // MARK: - Device Helpers

    private func getDefaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func reportIssue(_ message: String) {
        logger.error("\(message)")
        DispatchQueue.main.async { [weak self] in
            self?.monitoringIssue = message
        }
    }

    private func clearIssue() {
        DispatchQueue.main.async { [weak self] in
            self?.monitoringIssue = nil
        }
    }
}
