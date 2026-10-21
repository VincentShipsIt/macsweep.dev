import Foundation
import Testing

@testable import MacSweepCore

@Suite(.serialized)
struct AnthropicMessagesHTTPTests {
    private func session(status: Int = 200, body: String, inspect: ((URLRequest) throws -> Void)? = nil) -> URLSession {
        AnthropicStub.handler = { request in
            try inspect?(request)
            return (status, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicStub.self]
        return URLSession(configuration: config)
    }

    private func complete(session: URLSession, system: String? = nil) async throws -> String {
        try await AnthropicMessagesClient.complete(
            prompt: "fixture", apiKey: "fixture-key", model: .haiku,
            system: system, session: session)
    }

    @Test func requestHeadersBodyAndOptionalSystem() async throws {
        for system in [nil, "", "instructions"] as [String?] {
            let stub = session(
                body: #"{"stop_reason":"end_turn","content":[{"type":"tool_use"},{"type":"text","text":"  result  "}]}"#
            ) { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url == AnthropicMessagesClient.endpoint)
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
                #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body: Data
                if let data = request.httpBody {
                    body = data
                } else {
                    let stream = try #require(request.httpBodyStream)
                    stream.open()
                    defer { stream.close() }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count > 0 else { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                    body = data
                }
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["model"] as? String == "claude-haiku-4-5")
                #expect(json["max_tokens"] as? Int == 2048)
                #expect(json["system"] as? String == (system?.isEmpty == false ? system : nil))
                let messages = try #require(json["messages"] as? [[String: String]])
                #expect(messages == [["role": "user", "content": "fixture"]])
            }
            defer { stub.invalidateAndCancel() }
            #expect(try await complete(session: stub, system: system) == "result")
        }
    }

    @Test func truncationEmptyAndMalformedResponsesFailExplicitly() async throws {
        let cases: [(String, String)] = [
            (#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#, "truncated"),
            (#"{"content":[{"type":"text","text":"  "}]}"#, "empty"),
            (#"{"content":[{"type":"tool_use"}]}"#, "unparseable"),
            ("not JSON", "unparseable")
        ]
        for (body, expected) in cases {
            let stub = session(body: body)
            defer { stub.invalidateAndCancel() }
            do {
                _ = try await complete(session: stub)
                Issue.record("Expected failure for \(expected)")
            } catch {
                #expect(error.localizedDescription.contains(expected))
            }
        }
    }

    @Test func httpAndTransportErrorsRemainVisible() async throws {
        let stub = session(status: 429, body: "rate limited")
        defer { stub.invalidateAndCancel() }
        do {
            _ = try await complete(session: stub)
            Issue.record("Expected HTTP error")
        } catch AnthropicMessagesClient.ClientError.httpFailure(let status, let body) {
            #expect(status == 429)
            #expect(body == "rate limited")
        }
        AnthropicStub.handler = { _ in throw URLError(.timedOut) }
        await #expect(throws: AnthropicMessagesClient.ClientError.self) {
            try await complete(session: stub)
        }
    }
}

private final class AnthropicStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
