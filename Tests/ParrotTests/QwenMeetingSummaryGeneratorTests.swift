import XCTest
@testable import Parrot

final class QwenMeetingSummaryGeneratorTests: XCTestCase {
    func testInformativeTitleMayUseTwelveWordsWhenContextRequiresIt() {
        let title = "Awards Submission Hero Screen Dark Light Modes and QR Code Flow"
        XCTAssertEqual(MeetingSummary.validatedContextualTitle(title), title)
    }

    func testUsesEveryTranscriptLeafAndReturnsGroundedSummary() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 80).build(from: [
            source(0, "We reviewed the Bloom launch plan and agreed to finish the landing page."),
            source(1, "Next, Anna will send the final copy on Friday."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                let quote = leafID == 0 ? "Bloom launch plan" : "Anna will send the final copy"
                return #"{"title":"Bloom Launch Planning","summary":"Bloom launch planning.","language":"en","confidence":0.9,"evidence":["\#(quote)"]}"#
            case .reduce:
                return #"{"title":"Bloom Launch Copy Handoff","summary":"The team reviewed the Bloom launch plan and agreed that Anna will send the final copy on Friday.","language":"en","confidence":0.92,"evidence":["Bloom launch plan","Anna will send the final copy"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 2)
            .generate(from: snapshot)

        XCTAssertEqual(
            result.summary,
            "The team reviewed the Bloom launch plan and agreed that Anna will send the final copy on Friday."
        )
        XCTAssertEqual(result.title, "Bloom Launch Copy Handoff")
        XCTAssertEqual(result.fingerprint, snapshot.fingerprint)
        XCTAssertTrue(result.coverageReceipt.isExact)
        let requests = await runtime.requests
        let mappedLeafIDs = requests.compactMap { request -> Int? in
            if case .map(let leafID) = request.stage { return leafID }
            return nil
        }
        XCTAssertEqual(mappedLeafIDs.sorted(), snapshot.leaves.map(\.id).sorted())
    }

    func testRejectsSummaryWhoseEvidenceWasNotPresentInSource() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [
            source(0, "We discussed the Polish onboarding flow."),
        ])
        let runtime = SummaryRuntimeStub { _ in
            #"{"title":"Approved Product Launch Date","summary":"A launch date was approved.","language":"en","confidence":0.99,"evidence":["launch date approved"]}"#
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertNil(result.summary)
        XCTAssertEqual(result.disposition, .completed)
    }

    func testRejectsShortVagueTitleEvenWhenSummaryIsUseful() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [
            source(0, "We reviewed the tournament submission errors and the rejected-state feedback flow."),
        ])
        let runtime = SummaryRuntimeStub { _ in
            #"{"title":"Player Experience","summary":"The team reviewed tournament submission errors and the rejected-state feedback flow.","language":"en","confidence":0.95,"evidence":["tournament submission errors","rejected-state feedback flow"]}"#
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertEqual(
            result.summary,
            "The team reviewed tournament submission errors and the rejected-state feedback flow."
        )
        XCTAssertNil(result.title)
    }

    func testRejectsLongerTitleMadeOnlyOfGenericProductWords() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [
            source(0, "We reviewed submit validation, rejected states, and review feedback."),
        ])
        let runtime = SummaryRuntimeStub { _ in
            #"{"title":"Feature Improvement and Review Plan","summary":"The team reviewed submit validation, rejected states, and review feedback.","language":"en","confidence":0.95,"evidence":["submit validation, rejected states"]}"#
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertNotNil(result.summary)
        XCTAssertNil(result.title)
    }

    func testFinalWholeMeetingPassReplacesGenericSingleLeafTitle() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [
            source(0, "We reviewed submit validation, rejected states, and review feedback."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map:
                return #"{"title":"Feature Improvement and Review Plan","summary":"The team reviewed submit validation, rejected states, and review feedback.","language":"en","confidence":0.9,"evidence":["submit validation, rejected states"]}"#
            case .reduce:
                return #"{"title":"Submit Validation and Rejected States","summary":"The team reviewed submit validation, rejected states, and review feedback.","language":"en","confidence":0.94,"evidence":["submit validation, rejected states"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertEqual(result.title, "Submit Validation and Rejected States")
        let requests = await runtime.requests
        XCTAssertEqual(requests.filter { if case .reduce = $0.stage { true } else { false } }.count, 1)
    }

    func testFinalPassCannotEraseDistinctiveAnchorOrDegradeSummary() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [
            source(0, "Awards submissions need portfolio screens and recordings."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map:
                return #"{"title":"Awards Submission Screens and Recordings","summary":"Awards submissions need portfolio screens and recordings.","language":"en","confidence":0.9,"evidence":["Awards submissions need portfolio screens and recordings"]}"#
            case .reduce:
                return #"{"title":"UI UX Screen Examples","summary":"General UI and UX improvements were discussed.","language":"en","confidence":0.96,"evidence":["Awards submissions need portfolio screens and recordings"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertEqual(result.title, "Awards Submission Screens and Recordings")
        XCTAssertEqual(result.summary, "Awards submissions need portfolio screens and recordings.")
    }

    func testRecurringWholeMeetingAnchorOutranksOneDetailedSideTopic() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 58).build(from: [
            source(0, "Awards screens and recordings need a portfolio layout."),
            source(1, "Awards submission also has a paywall integration."),
            source(2, "Account paywall setup is one implementation detail."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                switch leafID {
                case 0:
                    return #"{"title":"Awards Portfolio Screens and Recordings","summary":"Awards screens and recordings need a portfolio layout.","language":"en","confidence":0.88,"evidence":["Awards screens and recordings"]}"#
                case 1:
                    return #"{"title":"Awards Submission and Paywall Integration","summary":"Awards submission also has a paywall integration.","language":"en","confidence":0.9,"evidence":["Awards submission"]}"#
                default:
                    return #"{"title":"Account Paywall Setup Decisions","summary":"Account paywall setup is one implementation detail.","language":"en","confidence":0.94,"evidence":["Account paywall setup"]}"#
                }
            case .reduce:
                return #"{"title":"Account Paywall Setup Decisions","summary":"Awards assets and submission include a paywall implementation detail.","language":"en","confidence":0.96,"evidence":["Account paywall setup"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 8)
            .generate(from: snapshot)

        XCTAssertEqual(result.title, "Awards Submission and Paywall Integration")
    }

    func testFinalNaturalTitleOutranksAKeywordPileOfOneOffASRTerms() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 120).build(from: [
            source(0, "Aye Experience has Dark Light screens for the Awards submission."),
            source(1, "The Awards submission also needs portfolio recordings without Ernaut watermark."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                if leafID == 0 {
                    return #"{"title":"Aye Experience Dark Light Awards","summary":"Aye Experience has Dark and Light screens for the Awards submission.","language":"pl","confidence":0.9,"evidence":["Aye Experience has Dark Light screens"]}"#
                }
                return #"{"title":"Awards Submission Recordings Ernaut","summary":"The Awards submission needs portfolio recordings without the Ernaut watermark.","language":"pl","confidence":0.9,"evidence":["Awards submission also needs portfolio recordings"]}"#
            case .reduce(let depth, _):
                if depth == 1 {
                    return #"{"title":"Aye Experience Dark Light Awards Ernaut","summary":"Awards submission assets include Dark and Light portfolio screens and recordings without a watermark.","language":"pl","confidence":0.94,"evidence":["Aye Experience has Dark Light screens","Awards submission also needs portfolio recordings"]}"#
                }
                return #"{"title":"Awards Submission Screens and Recordings","summary":"Awards submission assets include portfolio screens and recordings without a watermark.","language":"pl","confidence":0.95,"evidence":["Awards submission also needs portfolio recordings"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 4)
            .generate(from: snapshot)

        XCTAssertEqual(result.title, "Awards Submission Screens and Recordings")
    }

    func testRussianEditorialTitleOutranksRepeatedEnglishASRLabel() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 100).build(from: [
            source(0, "Нужно написать status update клиентам."),
            source(1, "Чтобы клиенты не думали, что мы пропали."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                let quote = leafID == 0
                    ? "написать status update клиентам"
                    : "клиенты не думали, что мы пропали"
                return "{\"title\":\"Status Update to Avoid Missing Impression\",\"summary\":\"A status update for clients prevents a missing impression.\",\"language\":\"ru\",\"confidence\":0.9,\"evidence\":[\"\(quote)\"]}"
            case .reduce(let depth, _):
                if depth == 1 {
                    return #"{"title":"Status Update for Clients","summary":"Нужно отправить обновление статуса клиентам, чтобы они не думали, что команда пропала.","language":"ru","confidence":0.94,"evidence":["написать status update клиентам","клиенты не думали, что мы пропали"]}"#
                }
                return #"{"title":"Статус клиентам чтобы команда не пропала","summary":"Нужно отправить обновление статуса клиентам, чтобы они не думали, что команда пропала.","language":"ru","confidence":0.95,"evidence":["написать status update клиентам","клиенты не думали, что мы пропали"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 4)
            .generate(from: snapshot)

        XCTAssertEqual(result.title, "Статус клиентам чтобы команда не пропала")
    }

    func testPolishEditorialTitleOutranksEnglishUILabelPile() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 100).build(from: [
            source(0, "Omówiliśmy review layout formularza turnieju i missing fields."),
            source(1, "Sticky submit i duplicate bracket są częścią flow."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                if leafID == 0 {
                    return #"{"title":"Review Layout Missing Fields","summary":"The tournament form review covers its layout and missing fields.","language":"pl","confidence":0.9,"evidence":["review layout formularza turnieju i missing fields"]}"#
                }
                return #"{"title":"Sticky Submit and Duplicate Bracket","summary":"Sticky submit and duplicate bracket are part of the flow.","language":"pl","confidence":0.9,"evidence":["Sticky submit i duplicate bracket"]}"#
            case .reduce(let depth, _):
                if depth == 1 {
                    return #"{"title":"Review Layout Missing Fields and Sticky Submit","summary":"Formularz turnieju obejmuje missing fields, sticky submit i duplicate bracket.","language":"pl","confidence":0.94,"evidence":["review layout formularza turnieju i missing fields","Sticky submit i duplicate bracket"]}"#
                }
                return #"{"title":"Formularz turnieju i stany bracketu","summary":"Formularz turnieju obejmuje missing fields, sticky submit i duplicate bracket.","language":"pl","confidence":0.95,"evidence":["review layout formularza turnieju i missing fields","Sticky submit i duplicate bracket"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 4)
            .generate(from: snapshot)

        XCTAssertEqual(result.title, "Formularz turnieju i stany bracketu")
    }

    func testMixedNoisyMeetingUsesLanguageOfWholeMeetingSummary() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 95).build(from: [
            source(0, "Dashboard 1 jest głównym ekranem superadmina ze statystykami."),
            source(1, "A wrap for main panel and review life appears in noisy audio."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                if leafID == 0 {
                    return #"{"title":"Dashboard superadmina i statystyki","summary":"Dashboard 1 jest głównym ekranem superadmina ze statystykami.","language":"mixed","confidence":0.8,"evidence":["Dashboard 1 jest głównym ekranem superadmina ze statystykami"]}"#
                }
                return #"{"title":"Wrap Main Panel Review Life","summary":"Noisy audio mentions a wrap for main panel and review life.","language":"mixed","confidence":0.9,"evidence":["wrap for main panel and review life"]}"#
            case .reduce:
                return #"{"title":"Wrap Main Panel Review Life","summary":"Dashboard 1 jest głównym ekranem superadmina ze statystykami; nagranie zawiera też niejasną frazę o main panel.","language":"mixed","confidence":0.9,"evidence":["Dashboard 1 jest głównym ekranem superadmina ze statystykami","wrap for main panel and review life"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 4)
            .generate(from: snapshot)

        XCTAssertEqual(result.title, "Dashboard superadmina i statystyki")
    }

    func testReductionMapsParaphrasedEvidenceBackToRealSourceQuote() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 55).build(from: [
            source(0, "We reviewed the tournament bracket form and its fields."),
            source(1, "The duplicate bracket action must remain available."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                if leafID == 0 {
                    return #"{"title":"Tournament Bracket Form Setup","summary":"The tournament bracket form and fields were reviewed.","language":"en","confidence":0.9,"evidence":["tournament bracket form"]}"#
                }
                return #"{"title":"Tournament Bracket Duplicate Action","summary":"The duplicate bracket action must remain available.","language":"en","confidence":0.9,"evidence":["duplicate bracket action"]}"#
            case .reduce:
                return #"{"title":"Tournament Bracket Setup Decisions","summary":"The tournament bracket setup keeps the duplicate action and required fields.","language":"en","confidence":0.94,"evidence":["The team finalized bracket setup and duplication"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 4)
            .generate(from: snapshot)

        XCTAssertEqual(result.title, "Tournament Bracket Duplicate Action")
        XCTAssertEqual(
            result.summary,
            "The tournament bracket setup keeps the duplicate action and required fields."
        )
    }

    func testMapMapsParaphrasedEvidenceBackToExactTranscriptExcerpt() async {
        let transcript = "The tournament form keeps sticky submit and duplicate bracket actions."
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, transcript)])
        let runtime = SummaryRuntimeStub { _ in
            #"{"title":"Tournament Form Sticky Submit","summary":"The tournament form keeps sticky submit and duplicate bracket actions.","language":"en","confidence":0.94,"evidence":["The form retains submission and bracket duplication"]}"#
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertEqual(result.title, "Tournament Form Sticky Submit")
        XCTAssertEqual(
            result.summary,
            "The tournament form keeps sticky submit and duplicate bracket actions."
        )
    }

    func testRejectedReductionBatchCannotSilentlyDropMeetingPart() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 45).build(from: [
            source(0, "Alpha onboarding flow needs review."),
            source(1, "Beta bracket validation needs changes."),
            source(2, "Gamma export screen needs approval."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                switch leafID {
                case 0:
                    return #"{"title":"Alpha Onboarding Flow Review","summary":"Alpha onboarding flow needs review.","language":"en","confidence":0.9,"evidence":["Alpha onboarding flow needs review"]}"#
                case 1:
                    return #"{"title":"Beta Bracket Validation Changes","summary":"Beta bracket validation needs changes.","language":"en","confidence":0.9,"evidence":["Beta bracket validation needs changes"]}"#
                default:
                    return #"{"title":"Gamma Export Screen Approval","summary":"Gamma export screen needs approval.","language":"en","confidence":0.9,"evidence":["Gamma export screen needs approval"]}"#
                }
            case .reduce(let depth, let batch):
                if depth == 1, batch == 1 { return "truncated-json" }
                return #"{"title":"Alpha Onboarding and Beta Bracket","summary":"Alpha onboarding and Beta bracket changes were reviewed.","language":"en","confidence":0.92,"evidence":["Alpha onboarding flow needs review","Beta bracket validation needs changes"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 2)
            .generate(from: snapshot)

        XCTAssertNil(result.summary)
        XCTAssertNil(result.title)
    }

    func testRejectedMapLeafCannotSilentlyDropMeetingPart() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 48).build(from: [
            source(0, "Alpha onboarding flow needs review."),
            source(1, "Beta bracket validation needs changes."),
            source(2, "Gamma export screen needs approval."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                if leafID == 1 { return "truncated-json" }
                let quote = leafID == 0
                    ? "Alpha onboarding flow needs review"
                    : "Gamma export screen needs approval"
                return "{\"title\":\"Alpha Gamma Delivery Review\",\"summary\":\"Alpha and Gamma delivery work needs review.\",\"language\":\"en\",\"confidence\":0.9,\"evidence\":[\"\(quote)\"]}"
            case .reduce:
                return #"{"title":"Alpha Gamma Delivery Review","summary":"Alpha and Gamma delivery work needs review.","language":"en","confidence":0.92,"evidence":["Alpha onboarding flow needs review","Gamma export screen needs approval"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime, maxReductionFanIn: 8)
            .generate(from: snapshot)

        XCTAssertNil(result.summary)
        XCTAssertNil(result.title)
    }

    func testGroundedLowConfidenceResponseIsNotDiscarded() async {
        let transcript = "Noisy audio still confirms the tournament bracket validation flow."
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, transcript)])
        let runtime = SummaryRuntimeStub { _ in
            #"{"title":"Tournament Bracket Validation Flow","summary":"The tournament bracket validation flow was confirmed despite noisy audio.","language":"en","confidence":0.05,"evidence":["tournament bracket validation flow"]}"#
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertEqual(result.title, "Tournament Bracket Validation Flow")
        XCTAssertNotNil(result.summary)
    }

    func testExplicitEmptyFillerLeafStillCountsAsCovered() async {
        let snapshot = MeetingTitleSnapshotBuilder(maxLeafUTF8Bytes: 40).build(from: [
            source(0, "Alpha onboarding flow needs review."),
            source(1, "Okay. Thanks. Mm."),
        ])
        let runtime = SummaryRuntimeStub { request in
            switch request.stage {
            case .map(let leafID):
                if leafID == 1 {
                    return #"{"title":"","summary":"","language":"other","confidence":0.0,"evidence":[]}"#
                }
                return #"{"title":"Alpha Onboarding Flow Review","summary":"Alpha onboarding flow needs review.","language":"en","confidence":0.9,"evidence":["Alpha onboarding flow needs review"]}"#
            case .reduce:
                return #"{"title":"Alpha Onboarding Flow Review","summary":"Alpha onboarding flow needs review.","language":"en","confidence":0.9,"evidence":["Alpha onboarding flow needs review"]}"#
            }
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertEqual(result.title, "Alpha Onboarding Flow Review")
        XCTAssertEqual(result.summary, "Alpha onboarding flow needs review.")
    }

    func testSubstantiveNoisyFragmentCannotBeAcceptedAsSilence() async {
        let transcript = """
        То, что пишет Доминик, нужно использовать, чтобы сегодня ускорить разработку.
        Нужно выбрать конкретные решения и реализовать основной flow продукта.
        """
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, transcript)])
        let runtime = SummaryRuntimeStub { request in
            let attempt = if case .map = request.stage { true } else { false }
            if attempt, request.prompt.contains("REPAIR:") {
                return #"{"title":"Доминик ускоряет разработку","summary":"Предложения Доминика нужно применить, чтобы ускорить разработку основного flow.","language":"ru","confidence":0.6,"evidence":["Доминик, нужно использовать, чтобы сегодня ускорить разработку"]}"#
            }
            if attempt {
                return #"{"title":"","summary":"","language":"other","confidence":0.0,"evidence":[]}"#
            }
            return #"{"title":"Доминик ускоряет разработку","summary":"Предложения Доминика нужно применить, чтобы ускорить разработку основного flow.","language":"ru","confidence":0.7,"evidence":["Доминик, нужно использовать, чтобы сегодня ускорить разработку"]}"#
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertEqual(result.title, "Доминик ускоряет разработку")
        XCTAssertNotNil(result.summary)
        let mapRequests = await runtime.requests.filter {
            if case .map = $0.stage { return true }
            return false
        }
        XCTAssertEqual(mapRequests.count, 2)
    }

    func testLongRepeatedFillerMayStillBeAcceptedAsEmpty() async {
        let transcript = Array(repeating: "Okay, thanks. Mm hmm. You know.", count: 12)
            .joined(separator: " ")
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, transcript)])
        let runtime = SummaryRuntimeStub { _ in
            #"{"title":"","summary":"","language":"other","confidence":0.0,"evidence":[]}"#
        }

        let result = await QwenMeetingSummaryGenerator(runtime: runtime).generate(from: snapshot)

        XCTAssertNil(result.title)
        XCTAssertNil(result.summary)
        let requests = await runtime.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testDefersBeforeLoadingModelWhenMemoryAdmissionFails() async {
        let snapshot = MeetingTitleSnapshotBuilder().build(from: [source(0, "Product roadmap")])
        let runtime = SummaryRuntimeStub { _ in XCTFail("Runtime should not run"); return "" }
        let generator = QwenMeetingSummaryGenerator(
            runtime: runtime,
            memoryAdmission: { .deferredForMemoryPressure }
        )

        let result = await generator.generate(from: snapshot)

        XCTAssertEqual(result.disposition, .deferred(.memoryPressure))
        let requests = await runtime.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func source(_ index: Int, _ text: String) -> MeetingTitleSourceSegment {
        MeetingTitleSourceSegment(
            id: UUID(),
            startTime: Double(index),
            endTime: Double(index + 1),
            speakerLabel: index.isMultiple(of: 2) ? "Them" : "Me",
            text: text
        )
    }
}

private actor SummaryRuntimeStub: QwenSummaryRunning {
    private(set) var requests: [QwenSummaryRequest] = []
    private let handler: @Sendable (QwenSummaryRequest) -> String

    init(handler: @escaping @Sendable (QwenSummaryRequest) -> String) {
        self.handler = handler
    }

    func available() async -> Bool { true }
    func complete(_ request: QwenSummaryRequest) async throws -> String {
        requests.append(request)
        return handler(request)
    }
    func shutdown() async {}
    func shutdownImmediately() async {}
}
