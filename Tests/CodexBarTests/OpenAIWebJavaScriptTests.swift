#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct OpenAIWebJavaScriptTests {
    @Test
    func `missing callback times out without waiting for WebKit`() async throws {
        let started = Date()
        do {
            _ = try await OpenAIWebJavaScript.waitForResult(deadline: Date().addingTimeInterval(0.05)) { _ in }
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test
    func `expired deadline does not start JavaScript`() async throws {
        var started = false
        do {
            _ = try await OpenAIWebJavaScript.waitForResult(deadline: .distantPast) { _ in started = true }
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(!started)
    }

    @Test
    func `synchronous callback preserves result`() async throws {
        let value = Data("result".utf8)
        let result = try await OpenAIWebJavaScript.waitForResult(deadline: Date().addingTimeInterval(1)) {
            $0(.success(value))
        }
        #expect(result == value)
    }

    @Test
    func `JavaScript errors remain errors`() async throws {
        do {
            _ = try await OpenAIWebJavaScript.waitForResult(deadline: Date().addingTimeInterval(1)) {
                $0(.failure(URLError(.cannotDecodeContentData)))
            }
            Issue.record("Expected original error")
        } catch let error as URLError {
            #expect(error.code == .cannotDecodeContentData)
        }
    }

    @Test
    func `late and duplicate callbacks do not resume twice`() async throws {
        var reply: OpenAIWebJavaScript.Completion?
        do {
            _ = try await OpenAIWebJavaScript.waitForResult(deadline: Date().addingTimeInterval(0.05)) {
                reply = $0
            }
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        reply?(.success(Data()))
        reply?(.failure(URLError(.cancelled)))
    }

    @Test
    func `cancellation releases a pending evaluation before its deadline`() async throws {
        var reply: OpenAIWebJavaScript.Completion?
        let task = Task { @MainActor in
            try await OpenAIWebJavaScript.waitForResult(deadline: Date().addingTimeInterval(60)) { reply = $0 }
        }
        while reply == nil {
            await Task.yield()
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        reply?(.success(Data()))
    }

    @Test
    func `successful empty reply remains empty`() async throws {
        let result = try await OpenAIWebJavaScript.waitForResult(deadline: Date().addingTimeInterval(1)) {
            $0(.success(nil))
        }
        #expect(result == nil)
    }
}
#endif
