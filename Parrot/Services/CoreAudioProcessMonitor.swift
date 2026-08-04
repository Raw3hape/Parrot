import AppKit
import CoreAudio
import Foundation

enum CoreAudioCallbackKind: Hashable, Sendable {
    case activitiesChanged
    case processListChanged
    case audioServiceRestarted
}

struct CoreAudioProcessListenerDelta: Equatable, Sendable {
    let added: [AudioObjectID]
    let removed: [AudioObjectID]

    init(
        existing: some Sequence<AudioObjectID>,
        current: some Sequence<AudioObjectID>
    ) {
        let existingSet = Set(existing)
        let currentSet = Set(current)
        added = currentSet.subtracting(existingSet).sorted()
        removed = existingSet.subtracting(currentSet).sorted()
    }

    var hasChanges: Bool {
        !added.isEmpty || !removed.isEmpty
    }
}

/// CoreAudio may emit the same property notification many times before the
/// main actor can inspect the latest state. Keep at most one pending delivery
/// plus one coalesced follow-up per kind, instead of allocating an unbounded
/// Task for every realtime callback.
final class CoreAudioCallbackCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CoreAudioCallbackKind: Bool] = [:]

    @discardableResult
    func claim(_ kind: CoreAudioCallbackKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending[kind] != nil {
            pending[kind] = true
            return false
        }
        pending[kind] = false
        return true
    }

    /// Notifications accumulated during the debounce wait are already covered
    /// by the imminent fresh state read. Clear that marker so only a change
    /// arriving during the read itself requests a follow-up pass.
    func beginDelivery(_ kind: CoreAudioCallbackKind) {
        lock.lock()
        defer { lock.unlock() }
        guard pending[kind] != nil else { return }
        pending[kind] = false
    }

    /// Returns true when at least one notification arrived while the previous
    /// delivery was pending and a single follow-up pass should run.
    @discardableResult
    func finish(_ kind: CoreAudioCallbackKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let wasMarkedDirty = pending[kind] else { return false }
        if wasMarkedDirty {
            pending[kind] = false
            return true
        }
        pending.removeValue(forKey: kind)
        return false
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

@MainActor
protocol AudioProcessMonitoring: AnyObject {
    var onActivitiesChanged: (([AudioProcessActivity]) -> Void)? { get set }
    var isMonitoring: Bool { get }
    func start()
    func stop()
}

@MainActor
final class CoreAudioProcessMonitor: AudioProcessMonitoring {
    var onActivitiesChanged: (([AudioProcessActivity]) -> Void)?
    private(set) var isMonitoring = false

    private struct ListenerRegistration {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let callbackQueue = DispatchQueue(
        label: "com.uygar.parrot.call-detection.core-audio",
        qos: .utility
    )
    private var systemListeners: [ListenerRegistration] = []
    private var processListeners: [ListenerRegistration] = []
    private nonisolated let callbackCoalescer = CoreAudioCallbackCoalescer()
    private var monitoringGeneration = 0

    func start() {
        guard !isMonitoring else { return }
        monitoringGeneration += 1
        isMonitoring = true
        installSystemListeners()
        synchronizeProcessListeners()
        emitCurrentActivities()
    }

    func stop() {
        guard isMonitoring else { return }
        monitoringGeneration += 1
        isMonitoring = false
        remove(&processListeners)
        remove(&systemListeners)
        onActivitiesChanged?([])
    }

    private func installSystemListeners() {
        addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            kind: .processListChanged,
            storage: &systemListeners
        )
        addListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyServiceRestarted,
            kind: .audioServiceRestarted,
            storage: &systemListeners
        )
    }

    private func removeAndReinstallListenersAfterServiceRestart() {
        guard isMonitoring else { return }
        remove(&processListeners)
        remove(&systemListeners)
        installSystemListeners()
        synchronizeProcessListeners()
        emitCurrentActivities()
    }

    @discardableResult
    private func synchronizeProcessListeners() -> Bool {
        guard isMonitoring else { return false }
        let current = processObjectIDs()
        let delta = CoreAudioProcessListenerDelta(
            existing: processListeners.map(\.objectID),
            current: current
        )
        guard delta.hasChanges else { return false }

        if !delta.removed.isEmpty {
            removeProcessListeners(for: Set(delta.removed))
        }
        for objectID in delta.added {
            addListener(
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunningInput,
                kind: .activitiesChanged,
                storage: &processListeners
            )
            addListener(
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunningOutput,
                kind: .activitiesChanged,
                storage: &processListeners
            )
        }
        return true
    }

    private func addListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        kind: CoreAudioCallbackKind,
        storage: inout [ListenerRegistration]
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return }

        let generation = monitoringGeneration
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.enqueueCallback(kind, generation: generation)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            callbackQueue,
            block
        )
        guard status == noErr else { return }
        storage.append(
            ListenerRegistration(
                objectID: objectID,
                address: address,
                block: block
            )
        )
    }

    private nonisolated func enqueueCallback(
        _ kind: CoreAudioCallbackKind,
        generation: Int
    ) {
        guard callbackCoalescer.claim(kind) else { return }
        deliverCallback(kind, generation: generation)
    }

    private nonisolated func deliverCallback(
        _ kind: CoreAudioCallbackKind,
        generation: Int
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if kind != .audioServiceRestarted {
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.callbackCoalescer.beginDelivery(kind)
            if self.isMonitoring, self.monitoringGeneration == generation {
                self.handleCallback(kind)
            }
            if self.callbackCoalescer.finish(kind) {
                self.deliverCallback(kind, generation: generation)
            }
        }
    }

    private func handleCallback(_ kind: CoreAudioCallbackKind) {
        switch kind {
        case .activitiesChanged:
            emitCurrentActivities()
        case .processListChanged:
            if synchronizeProcessListeners() {
                emitCurrentActivities()
            }
        case .audioServiceRestarted:
            removeAndReinstallListenersAfterServiceRestart()
        }
    }

    private func remove(_ registrations: inout [ListenerRegistration]) {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &registration.address,
                callbackQueue,
                registration.block
            )
        }
        registrations.removeAll(keepingCapacity: true)
    }

    private func removeProcessListeners(for objectIDs: Set<AudioObjectID>) {
        var kept: [ListenerRegistration] = []
        kept.reserveCapacity(processListeners.count)
        for var registration in processListeners {
            if objectIDs.contains(registration.objectID) {
                AudioObjectRemovePropertyListenerBlock(
                    registration.objectID,
                    &registration.address,
                    callbackQueue,
                    registration.block
                )
            } else {
                kept.append(registration)
            }
        }
        processListeners = kept
    }

    private func emitCurrentActivities() {
        guard isMonitoring else { return }
        let activities = processObjectIDs().compactMap(activity(for:))
        onActivitiesChanged?(activities)
    }

    private func processObjectIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            system,
            &address,
            0,
            nil,
            &byteCount
        ) == noErr,
        byteCount > 0 else {
            return []
        }

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        let status = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                system,
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        return status == noErr ? objectIDs : []
    }

    private func activity(
        for objectID: AudioObjectID
    ) -> AudioProcessActivity? {
        guard let pid: pid_t = scalar(
            objectID,
            selector: kAudioProcessPropertyPID
        ) else {
            return nil
        }
        let runningInput: UInt32 = scalar(
            objectID,
            selector: kAudioProcessPropertyIsRunningInput
        ) ?? 0
        let runningOutput: UInt32 = scalar(
            objectID,
            selector: kAudioProcessPropertyIsRunningOutput
        ) ?? 0
        let application = NSRunningApplication(processIdentifier: pid)
        let bundleID = string(
            objectID,
            selector: kAudioProcessPropertyBundleID
        ) ?? application?.bundleIdentifier

        return AudioProcessActivity(
            audioObjectID: objectID,
            processID: pid,
            bundleIdentifier: bundleID,
            applicationName: application?.localizedName,
            isInputActive: runningInput != 0,
            isOutputActive: runningOutput != 0
        )
    }

    private func scalar<T>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            pointer
        )
        return status == noErr ? pointer.pointee : nil
    }

    private func string(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
