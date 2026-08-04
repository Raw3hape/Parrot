import CoreAudio
import Foundation

struct AudioRouteSnapshot: Equatable, Sendable {
    let inputDeviceID: AudioDeviceID
    let outputDeviceID: AudioDeviceID
}

enum AudioRouteChangeAction: Equatable, Sendable {
    case refreshDeviceNames
    case restartMicrophone
}

enum AudioRouteChangePolicy {
    static func actions(
        previous: AudioRouteSnapshot,
        current: AudioRouteSnapshot,
        engineConfigurationChanged: Bool = false
    ) -> [AudioRouteChangeAction] {
        var result: [AudioRouteChangeAction] = []
        if previous != current {
            result.append(.refreshDeviceNames)
        }
        if previous.inputDeviceID != current.inputDeviceID
            || engineConfigurationChanged {
            result.append(.restartMicrophone)
        }
        return result
    }
}

enum MicrophoneGapCompensation {
    static func missingFrames(
        previousBufferUptime: TimeInterval,
        currentBufferUptime: TimeInterval,
        currentBufferFrames: Int,
        sampleRate: Double
    ) -> Int64 {
        guard previousBufferUptime.isFinite,
              currentBufferUptime.isFinite,
              sampleRate > 0,
              currentBufferFrames >= 0 else { return 0 }
        let currentDuration = Double(currentBufferFrames) / sampleRate
        let missingSeconds = currentBufferUptime
            - previousBufferUptime
            - currentDuration
        guard missingSeconds > 0.005 else { return 0 }
        return max(0, Int64((missingSeconds * sampleRate).rounded()))
    }
}

struct MicrophoneCaptureGenerationGate: Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?

    mutating func begin() -> Token {
        generation &+= 1
        if generation == 0 { generation = 1 }
        activeGeneration = generation
        return Token(generation: generation)
    }

    func accepts(_ token: Token) -> Bool {
        activeGeneration == token.generation
    }

    mutating func end(_ token: Token) {
        if accepts(token) { activeGeneration = nil }
    }
}

/// Watches the system default input and output without polling. CoreAudio can
/// emit a burst of callbacks for one headphones transition, so delivery is
/// coalesced into one stable route snapshot.
final class DefaultAudioDeviceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.uygar.parrot.audio.route")
    private let lock = NSLock()
    private var listener: AudioObjectPropertyListenerBlock?
    private var pendingDelivery: DispatchWorkItem?
    private var onChange: ((AudioRouteSnapshot) -> Void)?

    func start(onChange: @escaping (AudioRouteSnapshot) -> Void) {
        stop()
        lock.withLock { self.onChange = onChange }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleDelivery()
        }
        lock.withLock { self.listener = listener }

        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
        }
    }

    func stop() {
        let old: (AudioObjectPropertyListenerBlock?, DispatchWorkItem?) = lock.withLock {
            let value = (listener, pendingDelivery)
            listener = nil
            pendingDelivery = nil
            onChange = nil
            return value
        }
        old.1?.cancel()
        guard let listener = old.0 else { return }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )
        }
    }

    deinit { stop() }

    static func currentSnapshot() -> AudioRouteSnapshot {
        AudioRouteSnapshot(
            inputDeviceID: defaultDeviceID(input: true),
            outputDeviceID: defaultDeviceID(input: false)
        )
    }

    private func scheduleDelivery() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let callback = self.lock.withLock { self.onChange }
            callback?(Self.currentSnapshot())
        }
        let old = lock.withLock { () -> DispatchWorkItem? in
            let old = pendingDelivery
            pendingDelivery = item
            return old
        }
        old?.cancel()
        queue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private static let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultDeviceID(input: Bool) -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.address(
            input ? kAudioHardwarePropertyDefaultInputDevice
                  : kAudioHardwarePropertyDefaultOutputDevice
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return 0 }
        return deviceID
    }
}
