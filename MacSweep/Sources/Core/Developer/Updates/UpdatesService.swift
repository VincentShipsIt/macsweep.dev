import Combine
import Foundation

@MainActor
final class UpdatesService: ObservableObject {
    @Published private(set) var inventory = UpdateInventory()
    @Published private(set) var outcomes: [UpdateOutcome] = []
    @Published private(set) var log = ""
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var hasChecked = false
    @Published private(set) var errorMessage: String?
    var scanner: UpdateScanner
    var executor: UpdateExecutor

    init(administratorUpdate: MasAdministratorUpdate? = nil) {
        var scanner = UpdateScanner()
        scanner.administratorAvailable = administratorUpdate != nil
        self.scanner = scanner
        executor = UpdateExecutor(scanner: scanner, administratorUpdate: administratorUpdate)
    }

    func dismissError() { errorMessage = nil }

    func check() async {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        errorMessage = nil
        defer {
            isChecking = false
            hasChecked = true
        }
        do { inventory = try await scanner.scan() } catch {
            inventory = .init()
            errorMessage = error.localizedDescription
        }
    }

    func upgrade(_ selected: [PackageUpdate], acknowledgements: UpdateAcknowledgements) async {
        guard !isUpdating, !isChecking, !selected.isEmpty else { return }
        isUpdating = true
        log = ""
        outcomes = []
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let consumer = Task { @MainActor [weak self] in
            for await chunk in stream {
                guard let self else { break }
                self.log += chunk
                if self.log.utf8.count > 262_144 { self.log = String(self.log.suffix(131_072)) }
            }
        }
        let decoder = StreamingUTF8Decoder()
        executor.scanner = scanner
        outcomes = await executor.upgrade(selected, acknowledgements: acknowledgements) { channel, data in
            let decoded = decoder.decode(data, from: channel)
            if !decoded.isEmpty { continuation.yield(decoded) }
        }
        for chunk in decoder.finish() { continuation.yield(chunk) }
        continuation.finish()
        await consumer.value
        isUpdating = false
        // Source reports retain partial failures while the results remain available below the refreshed list.
        await check()
    }
}
