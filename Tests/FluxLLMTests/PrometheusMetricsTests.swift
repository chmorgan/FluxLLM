import XCTest

@testable import FluxLLM

final class PrometheusMetricsTests: XCTestCase {
    func testParsesNamespacedCountersWithoutMatchingHistogramSuffixes() {
        let metrics = PrometheusMetrics(
            """
            # HELP vllm:generation_tokens_total Total generated tokens.
            # TYPE vllm:generation_tokens_total counter
            vllm:generation_tokens_total{model_name="small",worker="0"} 12 1720000000000
            vllm:generation_tokens_total{model_name="small",worker="1"} 8
            vllm:generation_tokens_total_bucket{le="+Inf"} 100
            vllm:generation_tokens_total_count 100
            """
        )

        XCTAssertEqual(metrics.samples.count, 4)
        XCTAssertEqual(metrics.sum("vllm:generation_tokens_total"), 20)
        XCTAssertEqual(metrics.matching("generation_tokens_total").count, 0)
    }

    func testDecodesEscapedLabelsWithoutSplittingQuotedPunctuation() {
        let metrics = PrometheusMetrics(
            #"tokens{model_name="model, {α}",path="folder\\weights",note="a\"b\nc",} 4"#
        )

        XCTAssertEqual(metrics.samples.count, 1)
        XCTAssertEqual(metrics.samples.first?.labels["model_name"], "model, {α}")
        XCTAssertEqual(metrics.samples.first?.labels["path"], #"folder\weights"#)
        XCTAssertEqual(metrics.samples.first?.labels["note"], "a\"b\nc")
        XCTAssertEqual(metrics.sum("tokens", model: "model, {α}"), 4)
    }

    func testLastDuplicateWinsRegardlessOfLabelOrder() {
        let metrics = PrometheusMetrics(
            """
            tokens{worker="0",model="large"} 10
            tokens{worker="1",model="large"} 20
            tokens{model="large",worker="0"} 15
            """
        )

        XCTAssertEqual(metrics.samples.count, 2)
        XCTAssertEqual(metrics.sum("tokens"), 35)
    }

    func testSeriesIdentityCannotCollideThroughLabelDelimiters() {
        let first = PrometheusMetric(name: "tokens", labels: ["a": "x,b=y"], value: 1)
        let second = PrometheusMetric(name: "tokens", labels: ["a": "x", "b": "y"], value: 2)
        let reordered = PrometheusMetric(name: "tokens", labels: ["b": "y", "a": "x"], value: 3)
        let unicode = PrometheusMetric(name: "tokens", labels: ["a": "😀:1:b"], value: 4)

        XCTAssertNotEqual(first.seriesKey, second.seriesKey)
        XCTAssertEqual(second.seriesKey, reordered.seriesKey)
        XCTAssertNotEqual(unicode.seriesKey, first.seriesKey)
    }

    func testModelFilterAcceptsBothCommonLabelsAndExcludesUnlabelledSamples() {
        let metrics = PrometheusMetrics(
            """
            tokens{model_name="small",worker="0"} 2
            tokens{model="small",worker="1"} 3
            tokens{model_name="large"} 100
            tokens 1000
            """
        )

        XCTAssertEqual(metrics.sum("tokens", model: "small"), 5)
        XCTAssertEqual(metrics.sum("tokens", model: "large"), 100)
        XCTAssertNil(metrics.sum("tokens", model: "missing"))
        XCTAssertEqual(metrics.sum("tokens"), 1105)
    }

    func testScientificNotationAndNonfiniteSamples() {
        let metrics = PrometheusMetrics(
            """
            rate{worker="0"} +1.25e2
            rate{worker="1"} -.5E+1
            rate{worker="2"} 2.
            rate{worker="3"} +Inf
            rate{worker="4"} -Inf
            rate{worker="5"} NaN
            """
        )

        XCTAssertEqual(metrics.samples.count, 6)
        XCTAssertEqual(metrics.matching("rate").count, 3)
        XCTAssertEqual(metrics.sum("rate"), 122)
        XCTAssertTrue(metrics.samples.last?.value.isNaN == true)
    }

    func testRejectsMalformedLinesWithoutLosingFollowingSamples() {
        let metrics = PrometheusMetrics(
            #"""
            123bad 3
            bad-name 3
            tokens{a="unterminated} 3
            tokens{a="bad\t"} 3
            tokens{a="one",a="two"} 3
            tokens{a="one",,} 3
            tokens{a=unquoted} 3
            tokens{}3
            tokens 1e+
            tokens 0x1p4
            tokens 2 extra
            tokens 2 123 trailing
            tokens 2 123.5
            tokens .
            tokens +
            valid{a="ok"} 7
            """#
        )

        XCTAssertEqual(
            metrics.samples, [PrometheusMetric(name: "valid", labels: ["a": "ok"], value: 7)])
    }

    func testWhitespaceEmptyLabelsAndSignedTimestamp() {
        let metrics = PrometheusMetrics("\t tokens{ worker = \"0\" , }\t0\t-123\r\nempty{} 4\n")

        XCTAssertEqual(metrics.sum("tokens"), 0)
        XCTAssertEqual(metrics.samples.first?.labels, ["worker": "0"])
        XCTAssertEqual(metrics.sum("empty"), 4)
        XCTAssertNil(metrics.sum("missing"))
        XCTAssertTrue(PrometheusMetrics(" # comment\n\n\t").samples.isEmpty)
    }

    func testInvalidLatestValueDoesNotExposeStaleDuplicateValue() {
        let metrics = PrometheusMetrics("tokens 20\ntokens NaN\n")

        XCTAssertEqual(metrics.samples.count, 1)
        XCTAssertTrue(metrics.matching("tokens").isEmpty)
        XCTAssertNil(metrics.sum("tokens"))
    }

    func testSumDoesNotReturnOverflowAsAUsableReading() {
        let metrics = PrometheusMetrics("tokens{worker=\"0\"} 1e308\ntokens{worker=\"1\"} 1e308\n")

        XCTAssertEqual(metrics.matching("tokens").count, 2)
        XCTAssertNil(metrics.sum("tokens"))
    }
}
