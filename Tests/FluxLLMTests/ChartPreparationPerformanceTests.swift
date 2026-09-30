import Darwin
import Foundation
import XCTest

@testable import FluxLLM

final class ChartPreparationPerformanceTests: XCTestCase {
    func testSyntheticPublicationsAdvanceAndKeepFixedRetention() throws {
        let snapshots = ChartPerformanceFixture.publications(
            retainedSeconds: 60, laneCount: 3, count: 4)
        XCTAssertEqual(Set(snapshots.map(\.publicationID)).count, 4)
        XCTAssertEqual(snapshots.map { $0.throughput.count }, [121, 121, 121, 121])
        for (previous, next) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertEqual(next.timestamp.timeIntervalSince(previous.timestamp), 1)
            XCTAssertEqual(
                Array(previous.throughput.dropFirst(2)), Array(next.throughput.dropLast(2)))
            XCTAssertEqual(
                Array(previous.systemGPU.dropFirst(2)), Array(next.systemGPU.dropLast(2)))
            XCTAssertEqual(
                Array(previous.toolObservation.dropFirst(2)),
                Array(next.toolObservation.dropLast(2)))
            XCTAssertEqual(previous.requestLanes.map(\.id), next.requestLanes.map(\.id))
            XCTAssertEqual(previous.toolActivity, next.toolActivity)
        }
        let first = try XCTUnwrap(snapshots.first)
        XCTAssertTrue(first.supportsToolActivity)
        XCTAssertEqual(first.requestLanes.filter { !$0.terminal && $0.endedAt == nil }.count, 1)
        XCTAssertEqual(first.toolActivity.filter { $0.kind == .call }.count, 3)
        XCTAssertEqual(first.toolActivity.filter { $0.kind == .resultSubmission }.count, 3)
    }

    func testEveryFreshPublicationPreparesAndSamePublicationReusesCache() {
        let snapshots = ChartPerformanceFixture.publications(
            retainedSeconds: 60, laneCount: 3, count: 4)
        let preparation = DashboardChartPreparation(clock: { ChartPerformanceFixture.initialNow })
        var previous: PreparedDashboardCharts?
        for snapshot in snapshots {
            let prepared = preparation.histories(snapshot: snapshot, duration: 60)
            if let previous { XCTAssertFalse(prepared === previous) }
            XCTAssertEqual(prepared.publicationID, snapshot.publicationID)
            for _ in 0..<3 {
                XCTAssertTrue(preparation.histories(snapshot: snapshot, duration: 60) === prepared)
            }
            assertComplete(prepared, laneCount: 3)
            previous = prepared
        }
    }

    func testAlignedVisibleMinuteMatchesLongerHistoryAcrossBucketBoundaries() throws {
        // Two minutes is sufficient for the ordinary correctness check. The opt-in
        // measurement repeats this comparison with a full 7,201-point hour.
        let snapshots = ChartPerformanceFixture.publications(
            retainedSeconds: 120, laneCount: 3, count: 4)
        let shortPreparation = DashboardChartPreparation(
            clock: { ChartPerformanceFixture.initialNow })
        let longPreparation = DashboardChartPreparation(
            clock: { ChartPerformanceFixture.initialNow })
        var counts: [Int] = []
        for snapshot in snapshots {
            let short = ChartPerformanceFixture.alignedVisibleHistory(from: snapshot)
            counts.append(short.throughput.count)
            let expected = longPreparation.histories(snapshot: snapshot, duration: 60)
            let actual = shortPreparation.histories(snapshot: short, duration: 60)
            assertEquivalent(actual, expected)
        }
        XCTAssertEqual(counts, [121, 123, 125, 121])

        // Publication 1 cuts through a bin. Its displayed mean still includes the
        // contributors before the viewport boundary; trimming them is incorrect.
        let snapshot = snapshots[1]
        let prepared = longPreparation.histories(snapshot: snapshot, duration: 60)
        let bucket = try XCTUnwrap(prepared.throughput.buckets.first)
        XCTAssertLessThan(bucket.start, snapshot.timestamp.addingTimeInterval(-60))
        XCTAssertEqual(bucket.count, 6)
        let contributors = snapshot.throughput.filter {
            $0.timestamp >= bucket.start && $0.timestamp <= bucket.end
        }
        XCTAssertEqual(
            bucket.value, contributors.reduce(0) { $0 + $1.value } / 6, accuracy: 0.000_001)
    }

    func testPairedHistoriesPreserveMissingObservationGaps() throws {
        let snapshot = try XCTUnwrap(
            ChartPerformanceFixture.publications(
                retainedSeconds: 120, laneCount: 3, count: 1
            ).first)
        let gap = snapshot.timestamp.addingTimeInterval(-12)
        let longer = ChartPerformanceFixture.withObservationGap(snapshot, at: gap)
        let shorter = ChartPerformanceFixture.alignedVisibleHistory(from: longer)
        let prepared = DashboardChartPreparation().histories(snapshot: longer, duration: 60)
        let paired = DashboardChartPreparation().histories(snapshot: shorter, duration: 60)
        assertEquivalent(paired, prepared)
        assertComplete(prepared, laneCount: 3)
        XCTAssertEqual(prepared.throughput.segments.count, 2)
        XCTAssertEqual(prepared.gpu.segments.count, 2)
        XCTAssertEqual(prepared.toolActivity?.segments.count, 2)
        XCTAssertNil(prepared.throughput.bucket(at: gap))
        XCTAssertNil(prepared.gpu.bucket(at: gap))
        XCTAssertNil(prepared.toolActivity?.bucket(at: gap))
    }

    func testFreshChartPublicationsReportCPUAndWallCost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLUXLLM_PERF_CHART"] == "1" else {
            throw XCTSkip("Set FLUXLLM_PERF_CHART=1 to measure fresh chart publications.")
        }
        var cases: [ChartPerformanceCase] = []
        var equivalentOutputs = true
        for (caseIndex, laneCount) in [1, 33, 256].enumerated() {
            let long = ChartPerformanceFixture.publications(
                retainedSeconds: 3_600, laneCount: laneCount)
            let short = long.map { ChartPerformanceFixture.alignedVisibleHistory(from: $0) }
            XCTAssertEqual(
                long.map { $0.throughput.count },
                Array(repeating: 7_201, count: ChartPerformanceFixture.publicationCount))
            // Alternate the order to make a systematic warm-cache advantage less
            // likely. Each case owns one preparation cache for the entire replay.
            let inputs =
                caseIndex.isMultiple(of: 2)
                ? [("minute-aligned", short), ("hour", long)]
                : [("hour", long), ("minute-aligned", short)]
            var paired: [ChartPerformanceCase] = []
            for (retention, snapshots) in inputs {
                paired.append(
                    try measurePublications(
                        snapshots, retention: retention, laneCount: laneCount))
            }
            let equal = paired[0].outputChecksums == paired[1].outputChecksums
            equivalentOutputs = equivalentOutputs && equal
            XCTAssertTrue(
                equal, "Visible output changed with retained history for \(laneCount) lanes")
            #if !DEBUG
                if laneCount == 256 {
                    let hour = try XCTUnwrap(paired.first { $0.retention == "hour" })
                    let minute = try XCTUnwrap(paired.first { $0.retention == "minute-aligned" })
                    XCTAssertLessThanOrEqual(
                        hour.maximumCPUSecondsPerPublication, 0.015,
                        "Every full-hour publication must stay within the 15 ms CPU budget")
                    XCTAssertLessThanOrEqual(
                        hour.totalCPUSeconds, minute.totalCPUSeconds * 2,
                        "Retained offscreen history must not double preparation CPU cost")
                }
            #endif
            cases.append(contentsOf: paired)
        }
        #if DEBUG
            let configuration = "debug"
        #else
            let configuration = "release"
        #endif
        let report = ChartPerformanceReport(
            configuration: configuration, equivalentOutputs: equivalentOutputs, cases: cases)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let path = environment["FLUXLLM_PERF_CHART_RESULT"], !path.isEmpty {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("FLUXLLM_CHART_PERFORMANCE_RESULT\n\(String(decoding: data, as: UTF8.self))")
    }

    private func measurePublications(
        _ snapshots: [ChartPresentationSnapshot], retention: String, laneCount: Int
    ) throws -> ChartPerformanceCase {
        // Exercise lazy runtime setup before timing. Fixture construction and all
        // assertions/checksums occur outside the measured preparation intervals.
        if let first = snapshots.first {
            _ = DashboardChartPreparation().histories(snapshot: first, duration: 60)
        }
        let preparation = DashboardChartPreparation(clock: { ChartPerformanceFixture.initialNow })
        var previousID: ObjectIdentifier?
        var measurements: [ChartPublicationMeasurement] = []
        var outputChecksums: [String] = []
        var freshPreparations = true
        var cacheReuse = true
        var completeOutputs = true
        for (index, snapshot) in snapshots.enumerated() {
            let cpuStart = try processCPUSeconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let prepared = preparation.histories(snapshot: snapshot, duration: 60)
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            let cpuEnd = try processCPUSeconds()
            measurements.append(
                ChartPublicationMeasurement(
                    index: index, rawSampleCount: snapshot.throughput.count,
                    cpuSeconds: cpuEnd - cpuStart,
                    wallSeconds: Double(wallEnd - wallStart) / 1_000_000_000))
            if let previousID {
                freshPreparations = freshPreparations && ObjectIdentifier(prepared) != previousID
            }
            freshPreparations =
                freshPreparations && prepared.publicationID == snapshot.publicationID
            cacheReuse =
                cacheReuse && preparation.histories(snapshot: snapshot, duration: 60) === prepared
            let expectedSampleCount = 121 + 2 * (index % 3)
            completeOutputs =
                completeOutputs && hasCompleteOutput(prepared, laneCount: laneCount)
                && prepared.throughput.buckets.count == 21 && prepared.gpu.buckets.count == 21
                && prepared.throughput.buckets.reduce(0, { $0 + $1.count }) == expectedSampleCount
                && prepared.gpu.buckets.reduce(0, { $0 + $1.count }) == expectedSampleCount
            outputChecksums.append(checksum(prepared))
            // Do not retain the old result and move its release cost outside the
            // next timed cache replacement. The cache already owns this result.
            previousID = ObjectIdentifier(prepared)
        }
        XCTAssertTrue(freshPreparations)
        XCTAssertTrue(cacheReuse)
        XCTAssertTrue(completeOutputs)
        return ChartPerformanceCase(
            retention: retention, laneCount: laneCount, measurements: measurements,
            outputChecksums: outputChecksums, freshPreparations: freshPreparations,
            cacheReuse: cacheReuse, completeOutputs: completeOutputs)
    }

    private func processCPUSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private func hasCompleteOutput(_ prepared: PreparedDashboardCharts, laneCount: Int) -> Bool {
        prepared.lanes.count == laneCount && prepared.omittedRequestCount == 0
            && prepared.lanes.filter { !$0.terminal && $0.endedAt == nil }.count == 1
            && prepared.toolActivity?.buckets.reduce(0, { $0 + $1.callCount }) == laneCount
            && prepared.toolActivity?.resultMarkers.count == laneCount
            && prepared.requestTools.count == laneCount
            && prepared.requestTools.values.allSatisfy {
                $0.buckets.reduce(0) { $0 + $1.callCount } == 1 && $0.resultMarkers.count == 1
            }
            && prepared.throughput.current != nil && prepared.gpu.current != nil
    }

    private func assertComplete(
        _ prepared: PreparedDashboardCharts, laneCount: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(hasCompleteOutput(prepared, laneCount: laneCount), file: file, line: line)
    }

    private func assertEquivalent(
        _ actual: PreparedDashboardCharts, _ expected: PreparedDashboardCharts,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (a, b) in [(actual.throughput, expected.throughput), (actual.gpu, expected.gpu)] {
            XCTAssertEqual(a.interval, b.interval, file: file, line: line)
            XCTAssertEqual(a.segments, b.segments, file: file, line: line)
            XCTAssertEqual(a.current, b.current, file: file, line: line)
            XCTAssertEqual(a.peak, b.peak, file: file, line: line)
            XCTAssertEqual(a.plotSegments, b.plotSegments, file: file, line: line)
            XCTAssertEqual(
                a.zeroFilledPlotSegments, b.zeroFilledPlotSegments, file: file, line: line)
        }
        XCTAssertEqual(actual.lanes, expected.lanes, file: file, line: line)
        XCTAssertEqual(actual.requestRails, expected.requestRails, file: file, line: line)
        XCTAssertEqual(actual.laneColorIndex, expected.laneColorIndex, file: file, line: line)
        XCTAssertEqual(
            actual.omittedRequestCount, expected.omittedRequestCount, file: file, line: line)
        assertEquivalentTools(actual.toolActivity, expected.toolActivity, file: file, line: line)
        XCTAssertEqual(
            Set(actual.requestTools.keys), Set(expected.requestTools.keys), file: file, line: line)
        for (id, history) in expected.requestTools {
            assertEquivalentTools(actual.requestTools[id], history, file: file, line: line)
        }
        XCTAssertEqual(checksum(actual), checksum(expected), file: file, line: line)
    }

    private func assertEquivalentTools(
        _ actual: ToolActivityHistory?, _ expected: ToolActivityHistory?,
        file: StaticString, line: UInt
    ) {
        XCTAssertEqual(actual?.interval, expected?.interval, file: file, line: line)
        XCTAssertEqual(actual?.segments, expected?.segments, file: file, line: line)
        XCTAssertEqual(actual?.resultMarkers, expected?.resultMarkers, file: file, line: line)
        XCTAssertEqual(actual?.current, expected?.current, file: file, line: line)
        XCTAssertEqual(actual?.peak, expected?.peak, file: file, line: line)
        XCTAssertEqual(actual?.plotSegments, expected?.plotSegments, file: file, line: line)
        XCTAssertEqual(
            actual?.zeroFilledPlotSegments, expected?.zeroFilledPlotSegments, file: file, line: line
        )
    }

    /// FNV-1a over stable output values, excluding publication UUIDs. Swift's
    /// randomized Hasher cannot compare records across separate benchmark runs.
    private func checksum(_ prepared: PreparedDashboardCharts) -> String {
        var digest = ChartOutputDigest()
        digest.add(prepared.windowEnd.timeIntervalSince1970)
        for history in [prepared.throughput, prepared.gpu] {
            digest.add(history.interval)
            digest.add(history.peak ?? -1)
            digest.add(history.current?.timestamp.timeIntervalSince1970 ?? -1)
            digest.add(history.current?.value ?? -1)
            digest.add(history.segments.count)
            for segment in history.segments {
                digest.add(segment.count)
                for bucket in segment {
                    digest.add(bucket.start.timeIntervalSince1970)
                    digest.add(bucket.end.timeIntervalSince1970)
                    digest.add(bucket.value)
                    digest.add(bucket.count)
                }
            }
        }
        func addTools(_ history: ToolActivityHistory) {
            digest.add(history.interval)
            digest.add(history.peak ?? -1)
            digest.add(history.current?.timestamp.timeIntervalSince1970 ?? -1)
            digest.add(history.current?.callsPerMinute ?? -1)
            digest.add(history.segments.count)
            for segment in history.segments {
                digest.add(segment.count)
                for bucket in segment {
                    digest.add(bucket.start.timeIntervalSince1970)
                    digest.add(bucket.end.timeIntervalSince1970)
                    digest.add(bucket.callCount)
                    digest.add(bucket.callsPerMinute)
                    digest.add(bucket.toolNames.count)
                    for toolName in bucket.toolNames {
                        digest.add(toolName)
                    }
                }
            }
            digest.add(history.resultMarkers.count)
            for result in history.resultMarkers {
                digest.add(result.id.uuidString)
                digest.add(result.timestamp.timeIntervalSince1970)
                digest.add(result.requestID?.uuidString ?? "")
            }
        }
        if let tools = prepared.toolActivity { addTools(tools) }
        digest.add(prepared.lanes.count)
        digest.add(prepared.omittedRequestCount)
        for lane in prepared.lanes {
            digest.add(lane.id.uuidString)
            digest.add(lane.outputTokens)
            digest.add(lane.outputIsEstimated ? 1 : 0)
            digest.add(lane.terminal ? 1 : 0)
            digest.add(lane.model ?? "")
            digest.add(lane.liveTPS)
            digest.add(lane.startedAt.timeIntervalSince1970)
            digest.add(lane.endedAt?.timeIntervalSince1970 ?? -1)
            if let assignment = prepared.requestRails.assignments[lane.id] {
                digest.add(assignment.track)
                digest.add(assignment.colorIndex)
            }
            if let tools = prepared.requestTools[lane.id] { addTools(tools) }
        }
        return String(format: "%016llx", digest.value)
    }
}

private struct ChartOutputDigest {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func add(_ number: Double) { addBits(number.bitPattern) }
    mutating func add(_ number: Int) { addBits(UInt64(bitPattern: Int64(number))) }
    mutating func add(_ string: String) {
        add(string.utf8.count)
        for byte in string.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }
    private mutating func addBits(_ number: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            value = (value ^ ((number >> shift) & 255)) &* 1_099_511_628_211
        }
    }
}

private struct ChartPublicationMeasurement: Codable {
    let index: Int
    let rawSampleCount: Int
    let cpuSeconds: Double
    let wallSeconds: Double
}

private struct ChartPerformanceCase: Encodable {
    let retention: String
    let laneCount: Int
    let measurements: [ChartPublicationMeasurement]
    let outputChecksums: [String]
    let freshPreparations: Bool
    let cacheReuse: Bool
    let completeOutputs: Bool

    var totalCPUSeconds: Double { measurements.reduce(0) { $0 + $1.cpuSeconds } }
    var totalWallSeconds: Double { measurements.reduce(0) { $0 + $1.wallSeconds } }
    var maximumCPUSecondsPerPublication: Double { measurements.map(\.cpuSeconds).max() ?? 0 }
    var maximumWallSecondsPerPublication: Double { measurements.map(\.wallSeconds).max() ?? 0 }

    enum CodingKeys: String, CodingKey {
        case retention, laneCount, measurements, outputChecksums
        case freshPreparations, cacheReuse, completeOutputs
        case totalCPUSeconds, totalWallSeconds, cpuSecondsPerPublication, wallSecondsPerPublication
        case maximumCPUSecondsPerPublication, maximumWallSecondsPerPublication
    }

    init(
        retention: String, laneCount: Int, measurements: [ChartPublicationMeasurement],
        outputChecksums: [String], freshPreparations: Bool, cacheReuse: Bool, completeOutputs: Bool
    ) {
        self.retention = retention
        self.laneCount = laneCount
        self.measurements = measurements
        self.outputChecksums = outputChecksums
        self.freshPreparations = freshPreparations
        self.cacheReuse = cacheReuse
        self.completeOutputs = completeOutputs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(retention, forKey: .retention)
        try container.encode(laneCount, forKey: .laneCount)
        try container.encode(measurements, forKey: .measurements)
        try container.encode(outputChecksums, forKey: .outputChecksums)
        try container.encode(freshPreparations, forKey: .freshPreparations)
        try container.encode(cacheReuse, forKey: .cacheReuse)
        try container.encode(completeOutputs, forKey: .completeOutputs)
        try container.encode(totalCPUSeconds, forKey: .totalCPUSeconds)
        try container.encode(totalWallSeconds, forKey: .totalWallSeconds)
        try container.encode(
            totalCPUSeconds / Double(measurements.count), forKey: .cpuSecondsPerPublication)
        try container.encode(
            totalWallSeconds / Double(measurements.count), forKey: .wallSecondsPerPublication)
        try container.encode(
            maximumCPUSecondsPerPublication, forKey: .maximumCPUSecondsPerPublication)
        try container.encode(
            maximumWallSecondsPerPublication, forKey: .maximumWallSecondsPerPublication)
    }
}

private struct ChartPerformanceReport: Encodable {
    let schemaVersion = 2
    let kind = "chart-preparation"
    let fixtureVersion = ChartPerformanceFixture.version
    let cpuClock = "getrusage(RUSAGE_SELF): user + system"
    let wallClock = "DispatchTime.uptimeNanoseconds"
    let visibleDurationSeconds = ChartPerformanceFixture.visibleDuration
    let publicationCount = ChartPerformanceFixture.publicationCount
    let timingIncludesFixtureConstruction = false
    let maximum256LaneCPUSecondsPerPublication = 0.015
    let maximum256LaneRetainedHistoryCPURatio = 2.0
    let budgetStatus: String
    let configuration: String
    let equivalentOutputs: Bool
    let cases: [ChartPerformanceCase]

    init(configuration: String, equivalentOutputs: Bool, cases: [ChartPerformanceCase]) {
        self.configuration = configuration
        self.equivalentOutputs = equivalentOutputs
        self.cases = cases
        budgetStatus = configuration == "release" ? "enforced" : "requires-release-build"
    }
}
