import AppKit

enum DockVisibilityPreference {
    static let key = "showInDock"
    static let defaultValue = false

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

@MainActor
enum ApplicationPresentationController {
    static func applyDockVisibility(showInDock: Bool) {
        applyDockVisibility(showInDock: showInDock, application: .shared)
    }

    static func applyDockVisibility(
        showInDock: Bool,
        application: NSApplication
    ) {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard application.activationPolicy() != policy else { return }

        application.setActivationPolicy(policy)

        // Switching back to a regular app should make Parrot immediately
        // discoverable instead of waiting for another click.
        if showInDock {
            application.activate(ignoringOtherApps: true)
        }
    }
}
