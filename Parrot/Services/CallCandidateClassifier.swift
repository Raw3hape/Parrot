import Foundation

struct CallCandidateClassifier {
    private struct RegisteredSource {
        let bundlePrefixes: [String]
        let familyID: String
        let displayName: String
        let kind: CallSourceKind
    }

    private struct ProviderMarker {
        let terms: [String]
        let displayName: String
    }

    private static let browsers: [RegisteredSource] = [
        .init(
            bundlePrefixes: ["com.google.Chrome"],
            familyID: "browser.chrome",
            displayName: "Google Chrome",
            kind: .browser
        ),
        .init(
            bundlePrefixes: ["com.apple.Safari"],
            familyID: "browser.safari",
            displayName: "Safari",
            kind: .browser
        ),
        .init(
            bundlePrefixes: ["company.thebrowser.Browser"],
            familyID: "browser.arc",
            displayName: "Arc",
            kind: .browser
        ),
        .init(
            bundlePrefixes: ["com.microsoft.edgemac"],
            familyID: "browser.edge",
            displayName: "Microsoft Edge",
            kind: .browser
        ),
        .init(
            bundlePrefixes: ["org.mozilla.firefox"],
            familyID: "browser.firefox",
            displayName: "Firefox",
            kind: .browser
        ),
        .init(
            bundlePrefixes: ["com.brave.Browser"],
            familyID: "browser.brave",
            displayName: "Brave",
            kind: .browser
        ),
    ]

    private static let nativeSources: [RegisteredSource] = [
        .init(
            bundlePrefixes: ["com.tinyspeck.slackmacgap"],
            familyID: "native.slack",
            displayName: "Slack",
            kind: .native
        ),
        .init(
            bundlePrefixes: ["us.zoom.xos"],
            familyID: "native.zoom",
            displayName: "Zoom",
            kind: .native
        ),
        .init(
            bundlePrefixes: ["com.microsoft.teams2", "com.microsoft.teams"],
            familyID: "native.teams",
            displayName: "Microsoft Teams",
            kind: .native
        ),
        .init(
            bundlePrefixes: ["com.tdesktop.Telegram"],
            familyID: "native.telegram",
            displayName: "Telegram",
            kind: .native
        ),
        .init(
            bundlePrefixes: ["com.viber.osx"],
            familyID: "native.viber",
            displayName: "Viber",
            kind: .native
        ),
        .init(
            bundlePrefixes: ["net.whatsapp.WhatsApp"],
            familyID: "native.whatsapp",
            displayName: "WhatsApp",
            kind: .native
        ),
        .init(
            bundlePrefixes: ["com.hnc.Discord", "com.discord.Discord"],
            familyID: "native.discord",
            displayName: "Discord",
            kind: .native
        ),
        .init(
            bundlePrefixes: [
                "com.apple.FaceTime",
                "com.apple.TelephonyUtilities",
                "com.apple.avconferenced",
            ],
            familyID: "system.facetime",
            displayName: "FaceTime",
            kind: .system
        ),
    ]

    private static let providerMarkers: [ProviderMarker] = [
        .init(
            terms: ["google meet", "meet.google.com"],
            displayName: "Google Meet"
        ),
        .init(
            terms: ["microsoft teams", "teams.microsoft.com"],
            displayName: "Microsoft Teams"
        ),
        .init(
            terms: ["zoom meeting", "zoom.us"],
            displayName: "Zoom"
        ),
        .init(
            terms: ["slack huddle", "huddle"],
            displayName: "Slack Huddle"
        ),
        .init(
            terms: ["whereby"],
            displayName: "Whereby"
        ),
        .init(
            terms: ["discord"],
            displayName: "Discord"
        ),
    ]

    func bestCandidate(
        activities: [AudioProcessActivity],
        windows: [CallWindowInfo]
    ) -> CallCandidate? {
        activities.compactMap { candidate(for: $0, windows: windows) }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.source.familyID < rhs.source.familyID
            }
            .first
    }

    private func candidate(
        for activity: AudioProcessActivity,
        windows: [CallWindowInfo]
    ) -> CallCandidate? {
        guard activity.isInputActive || activity.isOutputActive else {
            return nil
        }
        guard !matchesBundlePrefix(
            activity.bundleIdentifier,
            prefix: "com.uygar.parrot"
        ) else {
            return nil
        }

        if let source = registeredSource(for: activity) {
            let provider = matchedProvider(
                forBundleID: activity.bundleIdentifier,
                windows: windows
            )
            switch source.kind {
            case .browser:
                if let provider,
                   activity.isInputActive || activity.isOutputActive {
                    return providerCandidate(provider, in: source)
                }
                guard activity.isInputActive && activity.isOutputActive else {
                    return nil
                }
                return CallCandidate(
                    source: source,
                    promptDetail: "\(source.applicationName) is using the microphone",
                    confidence: .audioConfirmed
                )
            case .native, .system:
                if let provider {
                    return providerCandidate(provider, in: source)
                }
                guard activity.isInputActive else { return nil }
                return CallCandidate(
                    source: source,
                    promptDetail: "\(source.applicationName) is using the microphone",
                    confidence: activity.isOutputActive ? .audioConfirmed : .inputOnly
                )
            case .unknown:
                return nil
            }
        }

        guard let provider = matchedProvider(
            forBundleID: activity.bundleIdentifier,
            windows: windows
        ) else {
            return nil
        }
        let appName = sanitizedApplicationName(activity)
        let source = CallSource(
            familyID: "unknown.\(normalizedIdentifier(activity.bundleIdentifier ?? appName))",
            displayName: provider,
            applicationName: appName,
            kind: .unknown
        )
        return providerCandidate(provider, in: source)
    }

    private func registeredSource(
        for activity: AudioProcessActivity
    ) -> CallSource? {
        let registration = (Self.browsers + Self.nativeSources).first {
            entry in
            entry.bundlePrefixes.contains {
                matchesBundlePrefix(activity.bundleIdentifier, prefix: $0)
            }
        }
        guard let registration else { return nil }
        return CallSource(
            familyID: registration.familyID,
            displayName: registration.displayName,
            applicationName: registration.displayName,
            kind: registration.kind
        )
    }

    private func matchedProvider(
        forBundleID bundleID: String?,
        windows: [CallWindowInfo]
    ) -> String? {
        let relevantWindows = windows.filter { window in
            guard let bundleID,
                  let ownerBundleID = window.ownerBundleIdentifier else {
                return false
            }
            return matchesBundlePrefix(ownerBundleID, prefix: bundleID)
                || matchesBundlePrefix(bundleID, prefix: ownerBundleID)
        }
        let normalizedTitles = relevantWindows.map {
            $0.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ).lowercased()
        }
        return Self.providerMarkers.first { marker in
            normalizedTitles.contains { title in
                marker.terms.contains { title.contains($0) }
            }
        }?.displayName
    }

    private func providerCandidate(
        _ provider: String,
        in source: CallSource
    ) -> CallCandidate {
        let labeledSource = CallSource(
            familyID: source.familyID,
            displayName: provider,
            applicationName: source.applicationName,
            kind: source.kind
        )
        return CallCandidate(
            source: labeledSource,
            promptDetail: provider == source.applicationName
                ? provider
                : "\(provider) in \(source.applicationName)",
            confidence: .providerConfirmed
        )
    }

    private func matchesBundlePrefix(
        _ bundleID: String?,
        prefix: String
    ) -> Bool {
        guard let bundleID else { return false }
        return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
    }

    private func sanitizedApplicationName(
        _ activity: AudioProcessActivity
    ) -> String {
        let trimmed = activity.applicationName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : "Unknown app"
    }

    private func normalizedIdentifier(_ value: String) -> String {
        value.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { $0.append($1) }
    }
}
