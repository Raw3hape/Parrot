import AppKit

struct ParrotRunningInstance: Equatable, Sendable {
    let pid: pid_t
    let bundleURL: URL
}
enum ParrotInstanceDecision: Equatable, Sendable {
    case continueCurrent(terminatePIDs: [pid_t])
    case activateExistingAndTerminateCurrent(pid: pid_t)
    case launchCanonicalAndTerminateCurrent
}

enum ParrotInstancePolicy {
    static func decision(
        currentPID: pid_t,
        currentBundleURL: URL,
        canonicalBundleURL: URL,
        canonicalBundleExists: Bool,
        runningInstances: [ParrotRunningInstance]
    ) -> ParrotInstanceDecision {
        let current = normalized(currentBundleURL)
        let canonical = normalized(canonicalBundleURL)
        let others = runningInstances.filter { $0.pid != currentPID }

        if current != canonical, canonicalBundleExists {
            return .launchCanonicalAndTerminateCurrent
        }

        if let existingCanonical = others.first(where: {
            normalized($0.bundleURL) == canonical
        }) {
            return .activateExistingAndTerminateCurrent(pid: existingCanonical.pid)
        }

        let nonCanonicalPIDs = others
            .filter { normalized($0.bundleURL) != canonical }
            .map(\.pid)
            .sorted()
        return .continueCurrent(terminatePIDs: nonCanonicalPIDs)
    }

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

@MainActor
enum ParrotInstanceCoordinator {
    static let canonicalBundleURL = URL(fileURLWithPath: "/Applications/Parrot.app")

    /// Returns true only for the process that should finish launching. Every
    /// hand-off is graceful so an older copy can finalize an active recording.
    static func enforceSingleInstalledInstance() -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return true
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.uygar.parrot"
        let instances = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).compactMap { app -> ParrotRunningInstance? in
            guard let url = app.bundleURL else { return nil }
            return ParrotRunningInstance(pid: app.processIdentifier, bundleURL: url)
        }
        let decision = ParrotInstancePolicy.decision(
            currentPID: ProcessInfo.processInfo.processIdentifier,
            currentBundleURL: Bundle.main.bundleURL,
            canonicalBundleURL: canonicalBundleURL,
            canonicalBundleExists: FileManager.default.fileExists(
                atPath: canonicalBundleURL.path
            ),
            runningInstances: instances
        )

        switch decision {
        case let .continueCurrent(terminatePIDs):
            for pid in terminatePIDs {
                NSRunningApplication(processIdentifier: pid)?.terminate()
            }
            return true

        case let .activateExistingAndTerminateCurrent(pid):
            NSRunningApplication(processIdentifier: pid)?.activate(
                options: [.activateAllWindows]
            )
            NSApp.terminate(nil)
            return false

        case .launchCanonicalAndTerminateCurrent:
            NSWorkspace.shared.openApplication(
                at: canonicalBundleURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in
                Task { @MainActor in NSApp.terminate(nil) }
            }
            return false
        }
    }
}
