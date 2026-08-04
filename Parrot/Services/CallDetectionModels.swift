import Foundation

struct AudioProcessActivity: Equatable, Sendable {
    let audioObjectID: UInt32
    let processID: Int32
    let bundleIdentifier: String?
    let applicationName: String?
    let isInputActive: Bool
    let isOutputActive: Bool
}

struct CallWindowInfo: Equatable, Sendable {
    let ownerBundleIdentifier: String?
    let ownerName: String?
    let title: String
}

enum CallSourceKind: String, Equatable, Sendable {
    case browser
    case native
    case system
    case unknown
}

struct CallSource: Equatable, Sendable {
    let familyID: String
    let displayName: String
    let applicationName: String
    let kind: CallSourceKind
}

enum CallCandidateConfidence: Int, Comparable, Equatable, Sendable {
    case inputOnly = 1
    case audioConfirmed = 2
    case providerConfirmed = 3

    static func < (
        lhs: CallCandidateConfidence,
        rhs: CallCandidateConfidence
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct CallCandidate: Equatable, Sendable {
    let source: CallSource
    let promptDetail: String
    let confidence: CallCandidateConfidence

    var sessionKey: String { source.familyID }
}
