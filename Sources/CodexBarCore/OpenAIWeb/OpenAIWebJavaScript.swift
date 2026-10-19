#if os(macOS)
import Foundation
import WebKit

/// Bounds the caller's wait even when WebKit never invokes its completion handler.
/// A timeout releases the caller; it does not itself terminate JavaScript execution.
@MainActor
enum OpenAIWebJavaScript {
    typealias Completion = @MainActor @Sendable (Result<Data?, Error>) -> Void

    @MainActor
    private final class PendingEvaluation {
        var continuation: CheckedContinuation<Data?, Error>?
        var timeoutTask: Task<Void, Never>?

        func finish(_ result: Result<Data?, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            continuation.resume(with: result)
        }
    }

    static func evaluate(_ script: String, in webView: WKWebView, deadline: Date) async throws -> Any? {
        let data = try await self.waitForResult(deadline: deadline) { completion in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(Result {
                        try value.map { try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
                    })
                }
            }
        }
        return try data.map { try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
    }

    /// Callback seam permits testing hung and late WebKit replies without browser/account access.
    static func waitForResult(deadline: Date, start: (@escaping Completion) -> Void) async throws -> Data? {
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, remaining.isFinite else { throw URLError(.timedOut) }
        let pending = PendingEvaluation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pending.timeoutTask = Task { @MainActor [weak pending] in
                    do {
                        try await Task.sleep(for: .seconds(remaining))
                    } catch { return }
                    pending?.finish(.failure(URLError(.timedOut)))
                }
                start { [weak pending] result in
                    pending?.finish(result)
                }
            }
        } onCancel: {
            Task { @MainActor in
                pending.finish(.failure(CancellationError()))
            }
        }
        try Task.checkCancellation()
        return result
    }
}
#endif
