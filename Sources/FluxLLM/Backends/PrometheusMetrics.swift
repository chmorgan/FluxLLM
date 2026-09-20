/// One sample from the Prometheus text exposition format.
struct PrometheusMetric: Sendable, Equatable {
    let name: String
    let labels: [String: String]
    let value: Double

    /// Length prefixes prevent label values containing separators from colliding.
    var seriesKey: String {
        var components = [name]
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            components.append(key)
            components.append(value)
        }
        return components.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// Parses complete samples, ignoring metadata and malformed lines.
struct PrometheusMetrics: Sendable {
    let samples: [PrometheusMetric]

    init(_ text: String) {
        var parsed: [PrometheusMetric] = []
        var indices: [String: Int] = [:]

        // Split bytes so CRLF is handled as a line ending, even though Swift
        // treats CRLF as a single extended grapheme cluster in String.split.
        for line in text.utf8.split(separator: 10) {
            var parser = PrometheusSampleParser(line)
            guard let sample = parser.parse() else { continue }
            let key = sample.seriesKey
            if let index = indices[key] {
                // Keep only the latest occurrence of a series in this scrape.
                parsed[index] = sample
            } else {
                indices[key] = parsed.count
                parsed.append(sample)
            }
        }

        samples = parsed
    }

    func matching(_ name: String, model: String? = nil) -> [PrometheusMetric] {
        samples.filter { sample in
            guard sample.name == name, sample.value.isFinite else { return false }
            guard let model else { return true }
            return sample.labels["model_name"] == model || sample.labels["model"] == model
        }
    }

    func sum(_ name: String, model: String? = nil) -> Double? {
        let matches = matching(name, model: model)
        guard !matches.isEmpty else { return nil }
        let total = matches.reduce(0) { $0 + $1.value }
        return total.isFinite ? total : nil
    }
}

private struct PrometheusSampleParser {
    private let bytes: [UInt8]
    private var position = 0

    init<Line: Collection>(_ line: Line) where Line.Element == UInt8 {
        bytes = Array(line)
    }

    mutating func parse() -> PrometheusMetric? {
        skipWhitespace()
        guard let name = readName(allowColon: true) else { return nil }

        var labels: [String: String] = [:]
        if consume(123) {  // {
            skipWhitespace()
            if !consume(125) {  // }
                while true {
                    guard let key = readName(allowColon: false) else { return nil }
                    skipWhitespace()
                    guard consume(61) else { return nil }  // =
                    skipWhitespace()
                    guard let value = readQuotedString(), labels[key] == nil else { return nil }
                    labels[key] = value
                    skipWhitespace()
                    if consume(125) { break }
                    guard consume(44) else { return nil }  // ,
                    skipWhitespace()
                    if consume(125) { break }  // A trailing label comma is valid.
                }
            }
        }

        guard skipWhitespace() else { return nil }
        let valueText = readToken()
        guard let value = Self.parseValue(valueText) else { return nil }

        skipWhitespace()
        if position < bytes.count {
            // Prometheus text timestamps are optional signed integer milliseconds.
            guard Self.isInteger(readToken()) else { return nil }
            skipWhitespace()
        }
        guard position == bytes.count else { return nil }
        return PrometheusMetric(name: name, labels: labels, value: value)
    }

    private mutating func readName(allowColon: Bool) -> String? {
        let start = position
        guard position < bytes.count,
            Self.isNameStart(bytes[position], allowColon: allowColon)
        else { return nil }
        position += 1
        while position < bytes.count {
            let byte = bytes[position]
            guard Self.isNameStart(byte, allowColon: allowColon) || Self.isDigit(byte) else {
                break
            }
            position += 1
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private mutating func readQuotedString() -> String? {
        guard consume(34) else { return nil }  // "
        var decoded: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == 34 {
                return String(decoding: decoded, as: UTF8.self)
            }
            if byte == 92 {  // \
                guard position < bytes.count else { return nil }
                let escaped = bytes[position]
                position += 1
                switch escaped {
                case 34, 92: decoded.append(escaped)
                case 110: decoded.append(10)  // \n
                default: return nil
                }
            } else {
                guard byte != 10, byte != 13 else { return nil }
                decoded.append(byte)
            }
        }
        return nil
    }

    private mutating func readToken() -> ArraySlice<UInt8> {
        let start = position
        while position < bytes.count, !Self.isWhitespace(bytes[position]) {
            position += 1
        }
        return bytes[start..<position]
    }

    @discardableResult
    private mutating func skipWhitespace() -> Bool {
        let start = position
        while position < bytes.count, Self.isWhitespace(bytes[position]) {
            position += 1
        }
        return position != start
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    private static func parseValue(_ bytes: ArraySlice<UInt8>) -> Double? {
        let text = String(decoding: bytes, as: UTF8.self)
        switch text {
        case "Inf", "+Inf": return .infinity
        case "-Inf": return -.infinity
        case "NaN": return .nan
        default: break
        }

        // Validate the decimal grammar before Double, which also accepts formats
        // such as hexadecimal floats that are not Prometheus sample values.
        let digits = Array(bytes)
        var index = 0
        if index < digits.count, digits[index] == 43 || digits[index] == 45 {
            index += 1
        }
        var mantissaDigits = 0
        while index < digits.count, isDigit(digits[index]) {
            index += 1
            mantissaDigits += 1
        }
        if index < digits.count, digits[index] == 46 {
            index += 1
            while index < digits.count, isDigit(digits[index]) {
                index += 1
                mantissaDigits += 1
            }
        }
        guard mantissaDigits > 0 else { return nil }
        if index < digits.count, digits[index] == 69 || digits[index] == 101 {
            index += 1
            if index < digits.count, digits[index] == 43 || digits[index] == 45 {
                index += 1
            }
            let exponentStart = index
            while index < digits.count, isDigit(digits[index]) { index += 1 }
            guard index > exponentStart else { return nil }
        }
        guard index == digits.count else { return nil }
        return Double(text)
    }

    private static func isInteger(_ bytes: ArraySlice<UInt8>) -> Bool {
        var value = bytes
        if value.first == 43 || value.first == 45 { value = value.dropFirst() }
        return !value.isEmpty && value.allSatisfy(isDigit)
    }

    private static func isNameStart(_ byte: UInt8, allowColon: Bool) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
            || (allowColon && byte == 58)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 13
    }
}
