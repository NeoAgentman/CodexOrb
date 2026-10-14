import Foundation
import CodexOrbCore

@MainActor
final class ServiceStatusMonitor {
    private(set) var state = OpenAIServiceStatusState()
    var onUpdate: ((OpenAIServiceStatusState) -> Void)?
    private var task: Task<Void, Never>?
    private let interval: Duration
    private let fetch: @Sendable () async throws -> OpenAIServiceStatus

    init(interval: Duration = .seconds(60),
         fetch: @escaping @Sendable () async throws -> OpenAIServiceStatus = { try await OpenAIServiceStatusSource().fetch() }) {
        self.interval = interval
        self.fetch = fetch
    }

    func start() {
        stop()
        task = Task { @MainActor [weak self, fetch, interval] in
            while !Task.isCancelled {
                do {
                    let snapshot = try await fetch()
                    guard !Task.isCancelled else { return }
                    self?.state.received(snapshot)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.state.failed()
                }
                self?.onUpdate?(self?.state ?? OpenAIServiceStatusState())
                do { try await Task.sleep(for: interval) }
                catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
