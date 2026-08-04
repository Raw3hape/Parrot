import AppKit
import CoreGraphics

@MainActor
protocol CallWindowProviding: AnyObject {
    func currentWindows() -> [CallWindowInfo]
}

@MainActor
final class CoreGraphicsCallWindowProvider: CallWindowProviding {
    func currentWindows() -> [CallWindowInfo] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return rawWindows.compactMap { dictionary in
            let title = (dictionary[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }

            let ownerName = dictionary[kCGWindowOwnerName as String] as? String
            let ownerPID = dictionary[kCGWindowOwnerPID as String] as? pid_t
            let bundleID = ownerPID.flatMap {
                NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
            }
            return CallWindowInfo(
                ownerBundleIdentifier: bundleID,
                ownerName: ownerName,
                title: title
            )
        }
    }
}
