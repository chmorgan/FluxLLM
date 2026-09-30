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

    func testAvailableSinceMatchesSnapshotAcrossSeriesAndExpiry() {
        let archive = ChartHistoryArchive(now: date(0))
        archive.record(
            source: "local", at: date(0), throughput: point(0, 0, available: false),
            gpu: point(0, 10), toolObservation: point(0, 0, available: false))
        archive.record(
            source: "local", at: date(1), throughput: point(1, 0, available: false),
            gpu: point(1, 0, available: false), toolObservation: point(1, 0))
        record(archive, at: 2, value: 20)

        let cases: [(Date, Date?)] = [
            (date(-1), nil), (date(3), date(0)),
            (date(86_400.5), date(1)), (date(86_403), nil),
        ]
        for (now, expected) in cases {
            let earliest = archive.availableSince(source: "local", now: now)
            let snapshot = archive.history(
                source: "local", before: now.addingTimeInterval(1), now: now)
            XCTAssertEqual(earliest, expected)
            XCTAssertEqual(earliest, snapshot.availableSince)
        }
        XCTAssertNil(archive.availableSince(source: "missing", now: date(86_403)))
        XCTAssertNil(
            archive.availableSince(source: "local", now: Date(timeIntervalSince1970: .nan)))
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

    func testNewSessionStartsEmptyAndDoesNotCreateHistoryDirectory() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = ChartHistoryArchive(directory: directory, now: date(0))
        await original.prepare()
        record(original, at: 0, value: 10)
        record(original, at: 1, value: 30)
        original.endSession(source: "local", at: date(1))
        original.flush()
        await original.flushAndWait()

        let nextSession = ChartHistoryArchive(directory: directory, now: date(2))
        await nextSession.prepare()
        XCTAssertEqual(nextSession.history(source: "local", before: date(3), now: date(3)), .empty)
        record(nextSession, at: 2, value: 60)
        await nextSession.flushAndWait()
        let history = nextSession.history(source: "local", before: date(3), now: date(3))

        XCTAssertNil(original.persistenceError)
        XCTAssertNil(nextSession.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [60])
        XCTAssertEqual(history.availableSince, date(2))
        XCTAssertEqual(history.systemGPU, history.throughput)
        XCTAssertEqual(history.toolObservation, history.throughput)
    }

    func testLegacyFilesAreNeverLoadedChangedOrDeleted() async throws {
        let savedBucket = #"{"start":0,"end":1,"value":900,"count":2}"#
        let valid = """
            {"version":1,"sources":{"local":{
            "throughput":[[\(savedBucket)]],"systemGPU":[[\(savedBucket)]],
            "toolObservation":[[\(savedBucket)]]}}}
            """
        for contents in [valid, "invalid chart history", #"{"version":99,"sources":{}}"#] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("chart-history.json")
            let original = Data(contents.utf8)
            try original.write(to: file)
            let beforeAttributes = try FileManager.default.attributesOfItem(atPath: file.path)

            // The legacy bucket is in January 2001, still within this query's retention.
            let archive = ChartHistoryArchive(
                directory: directory, now: Date(timeIntervalSinceReferenceDate: 2))
            await archive.prepare()
            XCTAssertEqual(
                archive.history(
                    source: "local", before: Date(timeIntervalSinceReferenceDate: 3),
                    now: Date(timeIntervalSinceReferenceDate: 3)), .empty)
            record(archive, at: 0, value: 10)
            archive.flush()
            record(archive, at: 1, value: 30)
            archive.endSession(source: "local", at: date(1))
            await archive.flushAndWait()

            let history = archive.history(source: "local", before: date(2), now: date(2))
            XCTAssertNil(archive.persistenceError)
            XCTAssertEqual(history.throughput.first?.first?.value, 20)
            XCTAssertEqual(history.throughput.first?.first?.count, 2)
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path),
                ["chart-history.json"])
            let afterAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(
                beforeAttributes[.modificationDate] as? Date,
                afterAttributes[.modificationDate] as? Date)
        }
    }

    func testBucketLimitWrapsWithoutJoiningRunsAndDuplicateReplacementRemainsExact() {
        let archive = ChartHistoryArchive(now: date(0))
        for index in 0..<25_000 {
            let time = Double(index) / 2
            record(archive, at: time, value: Double(index))
            archive.endSession(source: "local", at: date(time))
        }
        // A final run crosses a minute boundary after the ring has wrapped.
        record(archive, at: 12_539, value: 10)
        record(archive, at: 12_540, value: 20)
        record(archive, at: 12_540, value: 40)
        let history = archive.history(source: "local", before: date(12_541), now: date(12_541))
        let buckets = history.throughput.flatMap { $0 }

        XCTAssertEqual(buckets.count, 20_000)
        XCTAssertEqual(buckets.first?.start, date(2_501))
        XCTAssertEqual(history.throughput.count, 19_999)
        XCTAssertEqual(history.throughput.last?.map(\.value), [10, 40])
        XCTAssertEqual(history.throughput.last?.map(\.count), [1, 1])
        XCTAssertEqual(history.systemGPU, history.throughput)
        XCTAssertEqual(history.toolObservation, history.throughput)
    }

    func testRetentionExpiresWrappedPrefixAndRecordingCanResumeAfterFullExpiry() {
        let archive = ChartHistoryArchive(now: date(0))
        for index in 0..<25_000 {
            let time = Double(index)
            record(archive, at: time, value: Double(index))
            archive.endSession(source: "local", at: date(time))
        }
        let retained = archive.history(source: "local", before: date(25_000), now: date(96_400))
        XCTAssertEqual(retained.throughput.count, 15_000)
        XCTAssertEqual(retained.availableSince, date(10_000))
        XCTAssertEqual(
            archive.history(source: "local", before: date(120_000), now: date(120_000)), .empty)

        record(archive, at: 120_000, value: 5)
        record(archive, at: 120_001, value: 15)
        let resumed = archive.history(source: "local", before: date(120_002), now: date(120_002))
        XCTAssertEqual(resumed.throughput.count, 1)
        XCTAssertEqual(resumed.throughput.first?.first?.count, 2)
        XCTAssertEqual(resumed.throughput.first?.first?.value, 10)
    }

    func testSourceLimitEvictsOldestSourceWithoutMixingEndpoints() {
        let archive = ChartHistoryArchive(now: date(0))
        for index in 0..<40 {
            record(archive, at: Double(index), value: Double(index), source: "endpoint-\(index)")
        }
        for index in 0..<40 {
            let history = archive.history(
                source: "endpoint-\(index)", before: date(41), now: date(41))
            if index < 8 {
                XCTAssertEqual(history, .empty)
            } else {
                XCTAssertEqual(history.throughput.flatMap { $0 }.map(\.value), [Double(index)])
            }
        }
    }

    func testArchiveMatchesRawObservationReferenceAcrossCorrectionsGapsAndWindows() {
        let archive = ChartHistoryArchive(now: date(0))
        var reference = RawArchiveReference()
        for index in 1...4_000 {
            let time = Double(index) / 2 + Double(index / 900) * 90_000
            let sample = point(time, Double(index % 97), available: index % 11 != 0)
            archive.record(
                source: "local", at: sample.timestamp, throughput: sample,
                gpu: sample, toolObservation: sample)
            reference.record(sample)
            if index % 37 == 0 {
                let correction = point(time, 123, available: index % 74 != 0)
                archive.record(
                    source: "local", at: correction.timestamp, throughput: correction,
                    gpu: correction, toolObservation: correction)
                reference.record(correction)
            }
            if index % 41 == 0 {
                let backdated = point(time - 0.25, 900)
                archive.record(
                    source: "local", at: sample.timestamp, throughput: backdated,
                    gpu: backdated, toolObservation: backdated)
                reference.record(backdated)
            }
            if index % 83 == 0 {
                archive.endSession(source: "local", at: sample.timestamp)
                reference.endSession()
            }
            if index % 233 == 0 || index == 4_000 {
                for offset in [0.0, 0.25, 1, 60, 200] {
                    let before = date(time + 1 - offset)
                    let now = date(time + 1)
                    let actual = archive.history(source: "local", before: before, now: now)
                    let expected = reference.history(before: before, now: now)
                    assertBucketsEqual(actual.throughput, expected)
                    XCTAssertEqual(actual.systemGPU, actual.throughput)
                    XCTAssertEqual(actual.toolObservation, actual.throughput)
                }
            }
        }
    }

    private func assertBucketsEqual(
        _ actual: [[ArchivedChartBucket]], _ expected: [[ArchivedChartBucket]],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.map(\.count), expected.map(\.count), file: file, line: line)
        for (left, right) in zip(actual.flatMap({ $0 }), expected.flatMap({ $0 })) {
            XCTAssertEqual(left.start, right.start, file: file, line: line)
            XCTAssertEqual(left.end, right.end, file: file, line: line)
            XCTAssertEqual(left.count, right.count, file: file, line: line)
            XCTAssertEqual(left.value, right.value, accuracy: 0.000_000_001, file: file, line: line)
        }
    }

    /// Deliberately retains individual observations and recomputes all means on
    /// demand, independently of the production ring and incremental averages.
    private struct RawArchiveReference {
        var runs: [[TimeSeriesPoint]] = []
        var latest: TimeSeriesPoint?
        var latestAvailable = false
        var latestBeganRun = false
        var beginsRun = true

        mutating func endSession() {
            latest = nil
            beginsRun = true
        }

        mutating func record(_ point: TimeSeriesPoint) {
            if let latest, point.timestamp < latest.timestamp { return }
            if let previous = runs.last?.last, point.timestamp < previous.timestamp { return }
            let available = point.isAvailable && point.value.isFinite && point.value >= 0
            if latest?.timestamp == point.timestamp {
                if latestAvailable {
                    runs[runs.count - 1].removeLast()
                    if runs.last?.isEmpty == true { runs.removeLast() }
                }
                beginsRun = beginsRun || latestBeganRun || !latestAvailable
            }
            if available {
                let gap =
                    runs.last?.last.map { point.timestamp.timeIntervalSince($0.timestamp) }
                    ?? .infinity
                latestBeganRun = beginsRun || gap > 5 || runs.isEmpty
                if latestBeganRun {
                    runs.append([point])
                } else {
                    runs[runs.count - 1].append(point)
                }
                beginsRun = false
            } else {
                beginsRun = true
                latestBeganRun = false
            }
            latest = point
            latestAvailable = available
        }

        func history(before: Date, now: Date) -> [[ArchivedChartBucket]] {
            let cutoff = now.addingTimeInterval(-86_400)
            return runs.compactMap { run in
                var minutes: [[TimeSeriesPoint]] = []
                for point in run {
                    let minute = (point.timestamp.timeIntervalSince1970 / 60).rounded(.down)
                    let priorMinute = minutes.last?.last.map {
                        ($0.timestamp.timeIntervalSince1970 / 60).rounded(.down)
                    }
                    if minute == priorMinute {
                        minutes[minutes.count - 1].append(point)
                    } else {
                        minutes.append([point])
                    }
                }
                let buckets = minutes.map { points in
                    ArchivedChartBucket(
                        start: points.first!.timestamp, end: points.last!.timestamp,
                        value: points.reduce(0) { $0 + $1.value } / Double(points.count),
                        count: points.count)
                }.filter { $0.end >= cutoff && $0.end < before && $0.end <= now }
                return buckets.isEmpty ? nil : buckets
            }
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
