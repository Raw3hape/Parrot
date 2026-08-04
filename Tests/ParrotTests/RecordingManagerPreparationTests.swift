import SwiftData
import XCTest
@testable import Parrot

@MainActor
final class RecordingManagerPreparationTests: XCTestCase {
    func testApplicationPreparationDoesNotLoadSpeechModels() async throws {
        let manager = RecordingManager()
        let container = try makeContainer()

        await manager.prepareApplication(
            modelContext: ModelContext(container)
        )

        XCTAssertTrue(manager.isApplicationPrepared)
        XCTAssertFalse(manager.transcriptionEngine.isReady)
        if case .notLoaded = manager.transcriptionEngine.modelState {
            // Expected: startup remains lightweight until the user records.
        } else {
            XCTFail("Application startup must leave local speech models idle")
        }
    }

    func testMenuBarStartupPreparationDoesNotDependOnContentViewTask() async throws {
        let manager = RecordingManager()
        let container = try makeContainer()

        await ParrotStartupPreparation.run(
            recordingManager: manager,
            modelContainer: container
        )

        XCTAssertTrue(manager.isApplicationPrepared)
        XCTAssertFalse(manager.transcriptionEngine.isReady)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Meeting.self,
            TranscriptSegment.self,
            CallInsight.self,
            CallProfile.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
    }
}
