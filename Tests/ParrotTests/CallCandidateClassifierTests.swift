import XCTest
@testable import Parrot

final class CallCandidateClassifierTests: XCTestCase {
    private let classifier = CallCandidateClassifier()

    func testOutputOnlyMusicIsNotClassifiedAsCall() {
        let result = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.spotify.client",
                    name: "Spotify",
                    input: false,
                    output: true
                ),
            ],
            windows: []
        )

        XCTAssertNil(result)
    }

    func testChromeInputAndOutputCreatesTruthfulGenericCandidateWithoutTabTitle() {
        let result = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.google.Chrome.helper",
                    name: "Google Chrome Helper",
                    input: true,
                    output: true
                ),
            ],
            windows: []
        )

        XCTAssertEqual(result?.source.familyID, "browser.chrome")
        XCTAssertEqual(result?.source.displayName, "Google Chrome")
        XCTAssertEqual(result?.promptDetail, "Google Chrome is using the microphone")
        XCTAssertEqual(result?.confidence, .audioConfirmed)
    }

    func testGoogleMeetWindowLabelsChromeWithoutLeakingMeetingTitle() {
        let privateMeetingTitle = "Roadmap with Anna — Google Meet"
        let result = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.google.Chrome",
                    name: "Google Chrome",
                    input: true,
                    output: false
                ),
            ],
            windows: [
                .init(
                    ownerBundleIdentifier: "com.google.Chrome",
                    ownerName: "Google Chrome",
                    title: privateMeetingTitle
                ),
            ]
        )

        XCTAssertEqual(result?.source.familyID, "browser.chrome")
        XCTAssertEqual(result?.source.displayName, "Google Meet")
        XCTAssertEqual(result?.promptDetail, "Google Meet in Google Chrome")
        XCTAssertFalse(result?.promptDetail.contains("Anna") ?? true)
        XCTAssertFalse(result?.promptDetail.contains("Roadmap") ?? true)
        XCTAssertEqual(result?.confidence, .providerConfirmed)
    }

    func testKnownNativeCallAppInputAloneCreatesDebounceCandidate() {
        let result = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.tinyspeck.slackmacgap.helper",
                    name: "Slack Helper",
                    input: true,
                    output: false
                ),
            ],
            windows: []
        )

        XCTAssertEqual(result?.source.familyID, "native.slack")
        XCTAssertEqual(result?.source.displayName, "Slack")
        XCTAssertEqual(result?.confidence, .inputOnly)
    }

    func testFaceTimeAndTelephonyHelpersShareOneStableFamily() {
        let faceTime = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.apple.FaceTime",
                    name: "FaceTime",
                    input: true,
                    output: true
                ),
            ],
            windows: []
        )
        let helper = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.apple.FaceTime.FTConversationService",
                    name: "FaceTime Conversation Service",
                    input: true,
                    output: true
                ),
            ],
            windows: []
        )

        XCTAssertEqual(faceTime?.source.familyID, "system.facetime")
        XCTAssertEqual(helper?.source.familyID, "system.facetime")
        XCTAssertEqual(helper?.source.displayName, "FaceTime")
    }

    func testParrotOwnAudioIsAlwaysExcluded() {
        let result = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.uygar.parrot",
                    name: "Parrot",
                    input: true,
                    output: true
                ),
            ],
            windows: [
                .init(
                    ownerBundleIdentifier: "com.uygar.parrot",
                    ownerName: "Parrot",
                    title: "Google Meet"
                ),
            ]
        )

        XCTAssertNil(result)
    }

    func testUnknownInputOutputAppWithoutCallWindowIsIgnored() {
        let result = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.example.voice-recorder",
                    name: "Voice Recorder",
                    input: true,
                    output: true
                ),
            ],
            windows: []
        )

        XCTAssertNil(result)
    }

    func testOutputOnlyBrowserRequiresStrongCallWindow() {
        let noCall = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.google.Chrome",
                    name: "Google Chrome",
                    input: false,
                    output: true
                ),
            ],
            windows: [
                .init(
                    ownerBundleIdentifier: "com.google.Chrome",
                    ownerName: "Google Chrome",
                    title: "YouTube"
                ),
            ]
        )
        let mutedMeet = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.google.Chrome",
                    name: "Google Chrome",
                    input: false,
                    output: true
                ),
            ],
            windows: [
                .init(
                    ownerBundleIdentifier: "com.google.Chrome",
                    ownerName: "Google Chrome",
                    title: "Weekly sync — Google Meet"
                ),
            ]
        )

        XCTAssertNil(noCall)
        XCTAssertEqual(mutedMeet?.source.displayName, "Google Meet")
        XCTAssertEqual(mutedMeet?.confidence, .providerConfirmed)
    }

    func testSecondaryTeamsBundleCanUseItsOwnWindowForProviderLabel() {
        let result = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.microsoft.teams.helper",
                    name: "Microsoft Teams Helper",
                    input: true,
                    output: true
                ),
            ],
            windows: [
                .init(
                    ownerBundleIdentifier: "com.microsoft.teams",
                    ownerName: "Microsoft Teams",
                    title: "Daily standup — Microsoft Teams"
                ),
            ]
        )

        XCTAssertEqual(result?.source.familyID, "native.teams")
        XCTAssertEqual(result?.source.displayName, "Microsoft Teams")
        XCTAssertEqual(result?.confidence, .providerConfirmed)
    }

    func testUnattributedWindowCannotLabelAnUnrelatedAudioProcess() {
        let result = classifier.bestCandidate(
            activities: [
                activity(
                    bundleID: "com.example.audio-player",
                    name: "Audio Player",
                    input: false,
                    output: true
                ),
            ],
            windows: [
                .init(
                    ownerBundleIdentifier: nil,
                    ownerName: nil,
                    title: "Private meeting — Google Meet"
                ),
            ]
        )

        XCTAssertNil(result)
    }

    private func activity(
        bundleID: String?,
        name: String?,
        input: Bool,
        output: Bool
    ) -> AudioProcessActivity {
        .init(
            audioObjectID: 42,
            processID: 123,
            bundleIdentifier: bundleID,
            applicationName: name,
            isInputActive: input,
            isOutputActive: output
        )
    }
}
