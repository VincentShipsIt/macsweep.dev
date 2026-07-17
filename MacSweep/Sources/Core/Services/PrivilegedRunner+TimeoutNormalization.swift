import Foundation

extension PrivilegedRunner {
    /// Removes the private timeout sentinel and the wrapper that `osascript`
    /// adds around a non-zero `do shell script` result. Only marker-proven timeout
    /// payloads enter this path, so ordinary failures and launch errors retain
    /// their existing status and diagnostic behavior.
    static func normalizedTimeoutResult(
        _ result: ProcessResult,
        timeoutMarker: String
    ) -> ProcessResult {
        ProcessResult(
            status: result.status,
            output: normalizedTimeoutStream(result.output, timeoutMarker: timeoutMarker),
            error: normalizedTimeoutStream(result.error, timeoutMarker: timeoutMarker),
            outputWasValidUTF8: result.outputWasValidUTF8
        )
    }

    private static func normalizedTimeoutStream(
        _ stream: String,
        timeoutMarker: String
    ) -> String {
        guard stream.contains(timeoutMarker) else { return stream }

        var normalized = stream
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // `osascript` formats a shell exit as
        // "<line>:<column>: execution error: <stderr> (<status>)". Unwrap only
        // the exact timeout status and only after the unique marker proved this
        // is MacSweep's supervisor result. AppleScript flattens embedded newlines
        // to carriage returns, so restoring them can also expand intentional CRs
        // in the timeout payload; preserving readable captured lines takes
        // precedence for this error-only diagnostic.
        if let wrapper = normalized.range(of: ": execution error: "),
           normalized[..<wrapper.lowerBound].allSatisfy({ $0.isNumber || $0 == ":" }),
           let suffix = normalized.range(of: " (124)", options: .backwards),
           suffix.lowerBound > wrapper.upperBound {
            normalized = String(normalized[wrapper.upperBound..<suffix.lowerBound])
        }

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.compactMap { line -> String? in
            let value = String(line).replacingOccurrences(of: timeoutMarker, with: "")
            return value.isEmpty && line.contains(timeoutMarker) ? nil : value
        }.joined(separator: "\n")
    }
}
