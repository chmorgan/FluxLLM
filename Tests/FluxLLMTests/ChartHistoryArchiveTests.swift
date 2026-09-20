import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class ChartHistoryArchiveTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testMinuteBucketsPreserveActualSampleCountsAndMeans() {
        let archive = ChartHistoryArchive(now: date(58))

        record(archive, at: 58, value: 10)
        record(archive, at: 59, value: 20)
        record(archive, at: 60, value: 40)
        record(archive, at: 61, value: 80)
        record(archive, at: 62, value: 120)

        let history = archive.history(source: "local", before: date(63), now: date(63))
        let buckets = history.throughput.flatMap { $0 }

        XCTAssertEqual(history.throughput.count, 1)
        XCTAssertEqual(buckets.map(\.count), [2, 3])
        XCTAssertEqual(buckets.map(\.value), [15, 80])
        XCTAssertEqual(buckets.map(\.start), [date(58), date(60)])
        XCTAssertEqual(buckets.map(\.end), [date(59), date(62)])
        XCTAssertEqual(history.availableSince, date(58))
    }

    func testUnavailableSamplesSplitOnlyTheirOwnSeriesAndZeroRemainsValid() {
        let archive = ChartHistoryArchive(now: date(0))

        record(archive, at: 0, value: 0)
        archive.record(
            source: "local", at: date(1),
            throughput: point(1, 900, available: false),
            gpu: point(1, 30),
            toolObservation: point(1, 900, available: false))
        record(archive, at: 2, value: 0)

        let history = archive.history(source: "local", before: date(3), now: date(3))

        XCTAssertEqual(history.throughput.map(\.count), [1, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [0, 0])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.count), [1, 1])
        XCTAssertEqual(history.systemGPU.count, 1)
        XCTAssertEqual(history.systemGPU.first?.first?.count, 3)
        XCTAssertEqual(history.systemGPU.first?.first?.value, 10)
        XCTAssertEqual(history.toolObservation.map(\.count), [1, 1])
        XCTAssertEqual(history.toolObservation.flatMap { $0 }.map(\.value), [0, 0])
    }

    func testSamplingGapLongerThanFiveSecondsBreaksContinuity() {
        let archive = ChartHistoryArchive(now: date(0))

        record(archive, at: 0, value: 10)
        record(archive, at: 1, value: 20)
        record(archive, at: 6, value: 30)
        record(archive, at: 12, value: 40)
        record(archive, at: 13, value: 60)

        let history = archive.history(source: "local", before: date(14), now: date(14))

        XCTAssertEqual(history.throughput.map(\.count), [1, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.count), [3, 2])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [20, 50])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.start), [date(0), date(12)])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.end), [date(6), date(13)])
    }

    func testSwitchingSourcesKeepsValuesSeparateAndBreaksPreviousContinuity() {
        let archive = ChartHistoryArchive(now: date(0))

        record(archive, at: 0, value: 10, source: "first")
        record(archive, at: 1, value: 20, source: "first")
        record(archive, at: 2, value: 200, source: "second")
        record(archive, at: 3, value: 400, source: "second")
        record(archive, at: 4, value: 40, source: "first")
        record(archive, at: 5, value: 60, source: "first")

        let first = archive.history(source: "first", before: date(6), now: date(6))
        let second = archive.history(source: "second", before: date(6), now: date(6))
        let missing = archive.history(source: "missing", before: date(6), now: date(6))

        XCTAssertEqual(first.throughput.map(\.count), [1, 1])
        XCTAssertEqual(first.throughput.flatMap { $0 }.map(\.value), [15, 50])
        XCTAssertEqual(second.throughput.count, 1)
        XCTAssertEqual(second.throughput.first?.first?.value, 300)
        XCTAssertEqual(first.availableSince, date(0))
        XCTAssertEqual(second.availableSince, date(2))
        XCTAssertTrue(missing.throughput.isEmpty)
        XCTAssertNil(missing.availableSince)
    }

    func testCutoffExcludesWholeBucketWhoseEndReachesRecentHistory() {
        let archive = ChartHistoryArchive(now: date(58))

        record(archive, at: 58, value: 10)
        record(archive, at: 59, value: 20)
        record(archive, at: 60, value: 40)
        record(archive, at: 61, value: 80)

        let inside = archive.history(source: "local", before: date(60.5), now: date(62))
        let equal = archive.history(source: "local", before: date(61), now: date(62))
        let after = archive.history(source: "local", before: date(61.5), now: date(62))

        XCTAssertEqual(inside.throughput.flatMap { $0 }.map(\.value), [15])
        XCTAssertEqual(equal.throughput.flatMap { $0 }.map(\.value), [15])
        XCTAssertEqual(after.throughput.flatMap { $0 }.map(\.value), [15, 60])
    }

    func testHistoryExpiresAfterTwentyFourHoursEvenWithoutAnotherSample() {
        let archive = ChartHistoryArchive(now: date(0))

        record(archive, at: 0, value: 10)
        record(archive, at: 1, value: 20)
        record(archive, at: 86_401, value: 40)
        record(archive, at: 86_402, value: 60)

        let retained = archive.history(
            source: "local", before: date(86_403), now: date(86_402))
        let expired = archive.history(
            source: "local", before: date(172_804), now: date(172_803))

        XCTAssertEqual(retained.throughput.flatMap { $0 }.map(\.value), [50])
        XCTAssertEqual(retained.availableSince, date(86_401))
        XCTAssertTrue(expired.throughput.isEmpty)
        XCTAssertTrue(expired.systemGPU.isEmpty)
        XCTAssertTrue(expired.toolObservation.isEmpty)
        XCTAssertNil(expired.availableSince)
    }

    func testBackdatedSamplesAreIgnoredAndDuplicateTimestampReplacesLatestValue() {
        let archive = ChartHistoryArchive(now: date(0))

        record(archive, at: 0, value: 10)
        record(archive, at: 2, value: 30)
        record(archive, at: 1, value: 1_000)
        record(archive, at: 2, value: 50)

        let history = archive.history(source: "local", before: date(3), now: date(3))

        XCTAssertEqual(history.throughput.count, 1)
        XCTAssertEqual(history.throughput.first?.first?.value, 30)
        XCTAssertEqual(history.throughput.first?.first?.count, 2)
        XCTAssertEqual(history.throughput.first?.first?.start, date(0))
        XCTAssertEqual(history.throughput.first?.first?.end, date(2))
    }

    func testInvalidValuesSplitRunsWithoutEnteringTheAverage() {
        for invalid in [-1.0, .nan, .infinity, -.infinity] {
            let archive = ChartHistoryArchive(now: date(0))
            record(archive, at: 0, value: 10)
            record(archive, at: 1, value: invalid)
            record(archive, at: 2, value: 30)

            let history = archive.history(source: "local", before: date(3), now: date(3))

            XCTAssertEqual(history.throughput.map(\.count), [1, 1])
            XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [10, 30])
            XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.count), [1, 1])
        }
    }

    func testEndingSessionBreaksContinuityWhenSameSourceResumesImmediately() {
        let archive = ChartHistoryArchive(now: date(0))
        record(archive, at: 0, value: 10)
        record(archive, at: 1, value: 30)

        archive.endSession(source: "local", at: date(1))
        record(archive, at: 2, value: 60)
        let history = archive.history(source: "local", before: date(3), now: date(3))

        XCTAssertEqual(history.throughput.map(\.count), [1, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [20, 60])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.count), [2, 1])
    }

    func testBackdatedSamplesAfterEndingSessionAreIgnored() {
        let archive = ChartHistoryArchive(now: date(0))
        record(archive, at: 0, value: 10)
        record(archive, at: 2, value: 30)

        archive.endSession(source: "local", at: date(2))
        record(archive, at: 1, value: 1_000)
        record(archive, at: 3, value: 60)
        let history = archive.history(source: "local", before: date(4), now: date(4))

        XCTAssertEqual(history.throughput.map(\.count), [1, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [20, 60])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.count), [2, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.start), [date(0), date(3)])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.end), [date(2), date(3)])
    }

    func testCorrectingFirstSampleAfterUnavailableReadingPreservesGap() {
        let archive = ChartHistoryArchive(now: date(0))
        record(archive, at: 0, value: 10)
        let unavailable = point(1, 900, available: false)
        archive.record(
            source: "local", at: date(1), throughput: unavailable,
            gpu: unavailable, toolObservation: unavailable)
        record(archive, at: 2, value: 30)
        record(archive, at: 2, value: 50)

        let history = archive.history(source: "local", before: date(3), now: date(3))

        XCTAssertEqual(history.throughput.map(\.count), [1, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [10, 50])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.count), [1, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.start), [date(0), date(2)])
        XCTAssertEqual(history.systemGPU, history.throughput)
        XCTAssertEqual(history.toolObservation, history.throughput)
    }

    func testRestoredBucketsDoNotInventContinuityAcrossApplicationRestarts() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = ChartHistoryArchive(directory: directory, now: date(0))
        await original.prepare()
        record(original, at: 0, value: 10)
        record(original, at: 1, value: 30)
        await original.flushAndWait()

        let restored = ChartHistoryArchive(directory: directory, now: date(2))
        await restored.prepare()
        record(restored, at: 2, value: 60)
        let history = restored.history(source: "local", before: date(3), now: date(3))

        XCTAssertNil(original.persistenceError)
        XCTAssertNil(restored.persistenceError)
        XCTAssertEqual(history.throughput.map(\.count), [1, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [20, 60])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.count), [2, 1])
        XCTAssertEqual(history.availableSince, date(0))
        XCTAssertEqual(history.systemGPU, history.throughput)
        XCTAssertEqual(history.toolObservation, history.throughput)
    }

    func testSamplesCollectedWhileRestoringRemainAfterSavedHistory() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = ChartHistoryArchive(directory: directory, now: date(0))
        await original.prepare()
        record(original, at: 0, value: 10)
        record(original, at: 1, value: 30)
        await original.flushAndWait()

        let restored = ChartHistoryArchive(directory: directory, now: date(2))
        record(restored, at: 2, value: 60)
        await restored.prepare()
        let history = restored.history(source: "local", before: date(3), now: date(3))

        XCTAssertNil(restored.persistenceError)
        XCTAssertEqual(history.throughput.map(\.count), [1, 1])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [20, 60])
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.count), [2, 1])
        XCTAssertEqual(history.availableSince, date(0))
    }

    func testCorruptHistoryReportsErrorAndStartsWithEmptyHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid chart history".utf8).write(
            to: directory.appendingPathComponent("chart-history.json"))

        let archive = ChartHistoryArchive(directory: directory, now: date(0))
        await archive.prepare()
        let history = archive.history(source: "local", before: date(1), now: date(1))

        XCTAssertNotNil(archive.persistenceError)
        XCTAssertTrue(history.throughput.isEmpty)
        XCTAssertTrue(history.systemGPU.isEmpty)
        XCTAssertTrue(history.toolObservation.isEmpty)
        XCTAssertNil(history.availableSince)
    }

    func testUnreadableArchivesStayIntactWhileNewHistoryContinuesInMemory() async throws {
        for contents in ["invalid chart history", #"{"version":99,"sources":{}}"#] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("chart-history.json")
            let original = Data(contents.utf8)
            try original.write(to: file)

            let archive = ChartHistoryArchive(directory: directory, now: date(0))
            // Exercise a save queued before the asynchronous restore reports its error.
            record(archive, at: 0, value: 10)
            await archive.flushAndWait()
            let error = try XCTUnwrap(archive.persistenceError)

            record(archive, at: 1, value: 30)
            await archive.flushAndWait()
            let history = archive.history(source: "local", before: date(2), now: date(2))

            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(archive.persistenceError, error)
            XCTAssertEqual(history.throughput.first?.first?.value, 20)
            XCTAssertEqual(history.throughput.first?.first?.count, 2)
        }
    }

    private func record(
        _ archive: ChartHistoryArchive, at seconds: TimeInterval, value: Double,
        source: String = "local"
    ) {
        let sample = point(seconds, value)
        archive.record(
            source: source, at: date(seconds), throughput: sample,
            gpu: sample, toolObservation: sample)
    }

    private func point(
        _ seconds: TimeInterval, _ value: Double, available: Bool = true
    ) -> TimeSeriesPoint {
        TimeSeriesPoint(timestamp: date(seconds), value: value, isAvailable: available)
    }

    private func date(_ seconds: TimeInterval) -> Date {
        origin.addingTimeInterval(seconds)
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "FluxLLMChartHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }
}
