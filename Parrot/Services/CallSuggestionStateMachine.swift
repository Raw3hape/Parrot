import Foundation

struct CallSuggestionStateMachine {
    let debounceInterval: TimeInterval
    let idleResetInterval: TimeInterval

    private enum Phase {
        case idle
        case debouncing(candidate: CallCandidate, since: Date)
        case suggested(candidate: CallCandidate, absentSince: Date?)
        case suppressed(sessionKey: String, absentSince: Date?)
    }

    private var phase: Phase = .idle

    init(
        debounceInterval: TimeInterval = 4,
        idleResetInterval: TimeInterval = 12
    ) {
        self.debounceInterval = debounceInterval
        self.idleResetInterval = idleResetInterval
    }

    var suggestion: CallCandidate? {
        if case .suggested(let candidate, _) = phase {
            return candidate
        }
        return nil
    }

    var suppressedSessionKey: String? {
        if case .suppressed(let sessionKey, _) = phase {
            return sessionKey
        }
        return nil
    }

    var nextTransitionDate: Date? {
        switch phase {
        case .debouncing(_, let since):
            return since.addingTimeInterval(debounceInterval)
        case .suggested(_, let absentSince):
            return absentSince?.addingTimeInterval(idleResetInterval)
        case .suppressed(_, let absentSince):
            return absentSince?.addingTimeInterval(idleResetInterval)
        case .idle:
            return nil
        }
    }

    mutating func reset() {
        phase = .idle
    }

    mutating func update(
        candidate: CallCandidate?,
        now: Date,
        isRecording: Bool
    ) {
        if isRecording {
            suppressForRecording(candidate: candidate)
            return
        }

        guard let candidate else {
            noteInactivity(at: now)
            return
        }

        switch phase {
        case .idle:
            phase = .debouncing(candidate: candidate, since: now)

        case .debouncing(let previous, let since):
            guard previous.sessionKey == candidate.sessionKey else {
                phase = .debouncing(candidate: candidate, since: now)
                return
            }
            if now.timeIntervalSince(since) >= debounceInterval {
                phase = .suggested(candidate: candidate, absentSince: nil)
            } else {
                phase = .debouncing(candidate: candidate, since: since)
            }

        case .suggested(let previous, _):
            guard previous.sessionKey == candidate.sessionKey else {
                phase = .debouncing(candidate: candidate, since: now)
                return
            }
            phase = .suggested(candidate: candidate, absentSince: nil)

        case .suppressed(let sessionKey, _):
            guard sessionKey == candidate.sessionKey else {
                phase = .debouncing(candidate: candidate, since: now)
                return
            }
            phase = .suppressed(sessionKey: sessionKey, absentSince: nil)
        }
    }

    mutating func dismiss(now: Date) {
        guard let suggestion else { return }
        phase = .suppressed(
            sessionKey: suggestion.sessionKey,
            absentSince: nil
        )
    }

    mutating func accept(now: Date) {
        dismiss(now: now)
    }

    private mutating func suppressForRecording(
        candidate: CallCandidate?
    ) {
        if let candidate {
            phase = .suppressed(
                sessionKey: candidate.sessionKey,
                absentSince: nil
            )
            return
        }

        switch phase {
        case .debouncing(let candidate, _),
             .suggested(let candidate, _):
            phase = .suppressed(
                sessionKey: candidate.sessionKey,
                absentSince: nil
            )
        case .idle, .suppressed:
            break
        }
    }

    private mutating func noteInactivity(at now: Date) {
        switch phase {
        case .idle:
            return
        case .debouncing:
            phase = .idle
        case .suggested(let candidate, let absentSince):
            guard let absentSince else {
                phase = .suggested(
                    candidate: candidate,
                    absentSince: now
                )
                return
            }
            if now.timeIntervalSince(absentSince) >= idleResetInterval {
                phase = .idle
            }
        case .suppressed(let sessionKey, let absentSince):
            guard let absentSince else {
                phase = .suppressed(
                    sessionKey: sessionKey,
                    absentSince: now
                )
                return
            }
            if now.timeIntervalSince(absentSince) >= idleResetInterval {
                phase = .idle
            }
        }
    }
}
