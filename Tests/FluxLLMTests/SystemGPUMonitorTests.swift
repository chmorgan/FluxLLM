import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class SystemGPUMonitorTests: XCTestCase {
    private let configuration = BackendConfiguration(
        kind: .ollama, baseURL: URL(string: "http://127.0.0.1:11434")!)

    func testMeasuredZeroIsAvailableWithoutProcessCountersOrWarmup() async {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let monitor = SystemGPUMonitor(
            reader: {
                SystemGPURegistrySnapshot(devices: [.init(registryID: 1, utilizationPercent: 0)])
            },
            clock: { timestamp })

        let sample = await monitor.sample(configuration)

        XCTAssertEqual(sample.activityPercent, 0)
        XCTAssertEqual(sample.timestamp, timestamp)
        XCTAssertEqual(sample.scope, .system)
        XCTAssertTrue(sample.processIDs.isEmpty)
        XCTAssertNil(sample.unavailableReason)
        XCTAssertEqual(sample.source, "macOS system GPU utilization")
    }

    func testPercentageIsReportedDirectlyAtFractionalAndFullUtilization() async {
        for value in [23.5, 100.0] {
            let sample = await sample(devices: [.init(registryID: 1, utilizationPercent: value)])
            XCTAssertEqual(sample.activityPercent, value)
            XCTAssertEqual(sample.scope, .system)
            XCTAssertNil(sample.unavailableReason)
        }
    }

    func testMissingDevicesAndMissingOrInvalidCountersRemainUnavailable() async {
        let empty = await sample(devices: [])
        assertUnavailable(empty)

        let invalidValues: [Double?] = [nil, -1, 100.1, .nan, .infinity, -.infinity]
        for value in invalidValues {
            let result = await sample(devices: [.init(registryID: 1, utilizationPercent: value)])
            assertUnavailable(result)

            let partiallyReadable = await sample(
                devices: [
                    .init(registryID: 1, utilizationPercent: 0),
                    .init(registryID: 2, utilizationPercent: value),
                ])
            assertUnavailable(partiallyReadable)
        }
    }

    func testReaderFailureCannotBecomeMeasuredZero() async {
        let timestamp = Date(timeIntervalSince1970: 2_000)
        let monitor = SystemGPUMonitor(
            reader: { throw RegistryFailure.unavailable }, clock: { timestamp })

        let sample = await monitor.sample(configuration)

        assertUnavailable(sample)
        XCTAssertEqual(sample.timestamp, timestamp)
    }

    func testDuplicateRegistryEntriesAreDeduplicated() async {
        let sample = await sample(
            devices: [
                .init(registryID: 1, utilizationPercent: 75),
                .init(registryID: 1, utilizationPercent: 75),
            ])

        XCTAssertEqual(sample.activityPercent, 75)
        XCTAssertEqual(sample.source, "macOS system GPU utilization")
        XCTAssertNil(sample.unavailableReason)
    }

    func testConflictingDuplicateEntriesAreUnavailableRegardlessOfOrder() async {
        let conflictingValues: [[Double?]] = [[20, 40], [40, 20], [0, nil], [nil, 0]]
        for values in conflictingValues {
            let sample = await sample(
                devices: values.map { .init(registryID: 1, utilizationPercent: $0) })
            assertUnavailable(sample)
        }
    }

    func testMultipleGPUsUseSummedUtilizationOverSummedAvailablePercentage() async {
        let sample = await sample(
            devices: [
                .init(registryID: 1, utilizationPercent: 80),
                .init(registryID: 2, utilizationPercent: 20),
            ])

        XCTAssertEqual(sample.activityPercent, 50)
        XCTAssertEqual(sample.scope, .system)
        XCTAssertEqual(sample.source, "macOS system GPU utilization (average across 2 GPUs)")
        XCTAssertTrue(sample.processIDs.isEmpty)
        XCTAssertNil(sample.unavailableReason)
    }

    func testThreeGPUAverageIncludesIdleDevices() async throws {
        let sample = await sample(
            devices: [
                .init(registryID: 1, utilizationPercent: 65),
                .init(registryID: 2, utilizationPercent: 80),
                .init(registryID: 3, utilizationPercent: 0),
            ])

        XCTAssertEqual(try XCTUnwrap(sample.activityPercent), 145.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(sample.scope, .system)
        XCTAssertEqual(sample.source, "macOS system GPU utilization (average across 3 GPUs)")
        XCTAssertTrue(sample.processIDs.isEmpty)
        XCTAssertNil(sample.unavailableReason)
    }

    func testDuplicateDevicesDoNotChangeAverageWeights() async {
        let uniqueDevices: [SystemGPURegistryDevice] = [
            .init(registryID: 1, utilizationPercent: 80),
            .init(registryID: 2, utilizationPercent: 20),
        ]
        let unique = await sample(devices: uniqueDevices)
        let duplicated = await sample(
            devices: uniqueDevices + [uniqueDevices[0], uniqueDevices[0]])

        XCTAssertEqual(duplicated.activityPercent, 50)
        XCTAssertEqual(duplicated.activityPercent, unique.activityPercent)
        XCTAssertEqual(duplicated.source, unique.source)
        XCTAssertNil(duplicated.unavailableReason)
    }

    func testMultipleGPUZeroAndFullUtilizationStayWithinPercentageRange() async {
        for value in [0.0, 100.0] {
            let sample = await sample(
                devices: [
                    .init(registryID: 1, utilizationPercent: value),
                    .init(registryID: 2, utilizationPercent: value),
                    .init(registryID: 3, utilizationPercent: value),
                ])

            XCTAssertEqual(sample.activityPercent, value)
            XCTAssertEqual(sample.scope, .system)
            XCTAssertNil(sample.unavailableReason)
        }
    }

    func testRemoteBackendStillReportsThisMacAndResetDoesNotRequireWarmup() async {
        let monitor = SystemGPUMonitor(
            reader: {
                SystemGPURegistrySnapshot(devices: [.init(registryID: 1, utilizationPercent: 17)])
            })
        let remoteConfiguration = BackendConfiguration(
            kind: .vllm, baseURL: URL(string: "https://inference.example.test:8000")!)

        let beforeReset = await monitor.sample(remoteConfiguration)
        await monitor.reset()
        let afterReset = await monitor.sample(configuration)
        let withoutBackend = await monitor.sample(nil)

        for sample in [beforeReset, afterReset, withoutBackend] {
            XCTAssertEqual(sample.activityPercent, 17)
            XCTAssertEqual(sample.scope, .system)
            XCTAssertTrue(sample.processIDs.isEmpty)
            XCTAssertEqual(sample.source, "macOS system GPU utilization")
            XCTAssertNil(sample.unavailableReason)
        }
    }

    func testProcessExecutionRatioRemainsDistinctFromSystemPercentage() {
        let processSample = GPUActivitySample(activityPercent: 250, processIDs: [42])
        XCTAssertEqual(processSample.scope, .backendProcesses)
        XCTAssertEqual(processSample.activityPercent, 250)
        XCTAssertEqual(processSample.processIDs, [42])
    }

    func testRegistryParserReadsOnlyDeviceUtilizationNumber() {
        for value in [0.0, 23.5, 100.0] {
            let properties: NSDictionary = [
                "PerformanceStatistics": [
                    "Device Utilization %": NSNumber(value: value),
                    "Renderer Utilization %": NSNumber(value: 99),
                    "Tiler Utilization %": NSNumber(value: 98),
                ]
            ]
            XCTAssertEqual(IOKitSystemGPURegistry.utilizationPercent(properties: properties), value)
        }

        let rendererOnly: NSDictionary = [
            "PerformanceStatistics": ["Renderer Utilization %": NSNumber(value: 25)]
        ]
        XCTAssertNil(IOKitSystemGPURegistry.utilizationPercent(properties: rendererOnly))
        XCTAssertNil(
            IOKitSystemGPURegistry.utilizationPercent(
                properties: ["Device Utilization %": NSNumber(value: 25)]))
        XCTAssertNil(IOKitSystemGPURegistry.utilizationPercent(properties: [:]))
        XCTAssertNil(
            IOKitSystemGPURegistry.utilizationPercent(properties: ["PerformanceStatistics": "25"]))
    }

    func testRegistryParserRejectsBooleanStringsAndInvalidPercentages() {
        let malformed: [Any] = [
            NSNumber(value: true), NSNumber(value: false), "23", NSNull(),
            NSNumber(value: -1), NSNumber(value: 100.1), NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity), NSNumber(value: -Double.infinity),
        ]
        for value in malformed {
            XCTAssertNil(
                IOKitSystemGPURegistry.utilizationPercent(
                    properties: ["PerformanceStatistics": ["Device Utilization %": value]]),
                "Unexpected utilization from \(value)")
        }
    }

    func testLiveSystemGPUWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["FLUXLLM_SYSTEM_GPU_LIVE"] == "1" else {
            throw XCTSkip("Set FLUXLLM_SYSTEM_GPU_LIVE=1 to read this Mac's OS GPU utilization.")
        }
        let monitor = SystemGPUMonitor()
        let sample = await monitor.sample(configuration)
        let percent = try XCTUnwrap(
            sample.activityPercent,
            "Live System GPU unavailable: \(sample.unavailableReason ?? "unspecified reason")")

        XCTAssertTrue(percent.isFinite)
        XCTAssertGreaterThanOrEqual(percent, 0)
        XCTAssertLessThanOrEqual(percent, 100)
        XCTAssertEqual(sample.scope, .system)
        XCTAssertTrue(sample.processIDs.isEmpty)
        XCTAssertNil(sample.unavailableReason)
        XCTAssertFalse(sample.source.isEmpty)
        print("FluxLLM live System GPU validation: \(percent)%, source: \(sample.source)")
        await monitor.reset()
    }

    private func sample(devices: [SystemGPURegistryDevice]) async -> GPUActivitySample {
        let snapshot = SystemGPURegistrySnapshot(devices: devices)
        let monitor = SystemGPUMonitor(reader: { snapshot })
        return await monitor.sample(configuration)
    }

    private func assertUnavailable(
        _ sample: GPUActivitySample, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(sample.activityPercent, file: file, line: line)
        XCTAssertEqual(sample.scope, .system, file: file, line: line)
        XCTAssertTrue(sample.processIDs.isEmpty, file: file, line: line)
        XCTAssertFalse(sample.unavailableReason?.isEmpty ?? true, file: file, line: line)
    }

    private enum RegistryFailure: Error {
        case unavailable
    }
}
