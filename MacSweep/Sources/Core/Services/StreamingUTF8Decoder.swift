import Foundation

/// Incrementally decodes interleaved process output without corrupting a UTF-8
/// scalar that is split across pipe reads.
final class StreamingUTF8Decoder: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutputPending = Data()
    private var standardErrorPending = Data()

    func decode(_ chunk: Data, from stream: ProcessOutputStream) -> String {
        lock.lock()
        var buffer: Data
        switch stream {
        case .standardOutput:
            buffer = standardOutputPending
        case .standardError:
            buffer = standardErrorPending
        }
        buffer.append(chunk)

        let pendingCount = Self.trailingIncompleteByteCount(in: buffer)
        let decodableEnd = buffer.index(buffer.endIndex, offsetBy: -pendingCount)
        let decodable = Data(buffer[..<decodableEnd])
        let pending = Data(buffer[decodableEnd...])

        switch stream {
        case .standardOutput:
            standardOutputPending = pending
        case .standardError:
            standardErrorPending = pending
        }
        lock.unlock()

        // Invalid complete bytes should remain visible as replacement characters.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: decodable, as: UTF8.self)
    }

    /// Flushes incomplete terminal sequences as Unicode replacement characters
    /// once EOF proves that no continuation bytes can arrive.
    func finish() -> [String] {
        lock.lock()
        let pending = [standardOutputPending, standardErrorPending]
        standardOutputPending.removeAll(keepingCapacity: false)
        standardErrorPending.removeAll(keepingCapacity: false)
        lock.unlock()

        return pending
            .filter { !$0.isEmpty }
            .map {
                // EOF makes an incomplete scalar invalid, so preserve evidence.
                // swiftlint:disable:next optional_data_string_conversion
                return String(decoding: $0, as: UTF8.self)
            }
    }

    private static func trailingIncompleteByteCount(in data: Data) -> Int {
        guard !data.isEmpty else { return 0 }

        var continuationCount = 0
        for byte in data.reversed() {
            guard byte & 0xC0 == 0x80, continuationCount < 3 else { break }
            continuationCount += 1
        }

        let leadOffset = data.count - continuationCount - 1
        guard leadOffset >= 0 else { return 0 }
        let leadIndex = data.index(data.startIndex, offsetBy: leadOffset)
        let expectedCount: Int
        switch data[leadIndex] {
        case 0xC2...0xDF:
            expectedCount = 2
        case 0xE0...0xEF:
            expectedCount = 3
        case 0xF0...0xF4:
            expectedCount = 4
        default:
            return 0
        }

        let availableCount = continuationCount + 1
        return availableCount < expectedCount ? availableCount : 0
    }
}
