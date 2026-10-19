#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import CodexBarCore

/// Offline tests of the production acquisition/collection owners. No provider requests or cookies.
@MainActor
@Suite(.serialized)
struct OpenAIDashboardDeadlineIntegrationTests {
    private static let apiData = OpenAIDashboardFetcher.DashboardAPIData(
        primaryLimit: nil,
        secondaryLimit: nil,
        extraRateWindows: [],
        creditsRemaining: 42,
        codexCreditLimit: nil,
        accountPlan: nil)

    private func fetcher(
        cache: OpenAIDashboardWebViewCache,
        verified: Bool = true,
        usage: Bool = true) -> OpenAIDashboardFetcher
    {
        _ = NSApplication.shared
        var fetcher = OpenAIDashboardFetcher()
        fetcher.webViewCacheForTesting = cache
        fetcher.preflightForTesting = { _, _ in
            (usage ? Self.apiData : nil, verified ? "fixture@example.invalid" : nil)
        }
        return fetcher
    }

    @Test
    func `acquisition timeout returns verified API usage and cleans cache`() async throws {
        let cache = OpenAIDashboardWebViewCache()
        cache.prepareForTesting = { _, _, _ in throw URLError(.timedOut) }
        let fetcher = self.fetcher(cache: cache)
        let snapshot = try await fetcher.loadLatestDashboard(
            websiteDataStore: .nonPersistent(), logger: { print("acquisition: \($0)") }, timeout: 2)
        #expect(snapshot.creditsRemaining == 42)
        #expect(snapshot.signedInEmail == "fixture@example.invalid")
        #expect(cache.entryCount == 0)
        #expect(cache.activeAcquisitionCountForTesting == 0)
        print("PROOF acquisition timeout: verified credits=42, cache=0, acquisitions=0")
    }

    @Test
    func `exhausted preparation budget still returns verified API usage`() async throws {
        let cache = OpenAIDashboardWebViewCache()
        var fetcher = self.fetcher(cache: cache)
        fetcher.preflightForTesting = { _, _ in
            try await Task.sleep(for: .milliseconds(50))
            return (Self.apiData, "fixture@example.invalid")
        }
        let snapshot = try await fetcher.loadLatestDashboard(websiteDataStore: .nonPersistent(), timeout: 0.01)
        #expect(snapshot.creditsRemaining == 42)
        #expect(cache.entryCount == 0)
    }

    @Test(arguments: [false, true])
    func `acquisition timeout requires both verified identity and usage`(verified: Bool) async throws {
        let cache = OpenAIDashboardWebViewCache()
        cache.prepareForTesting = { _, _, _ in throw URLError(.timedOut) }
        let fetcher = self.fetcher(cache: cache, verified: verified, usage: !verified)
        do {
            _ = try await fetcher.loadLatestDashboard(websiteDataStore: .nonPersistent(), timeout: 2)
            Issue.record("Unverified or missing usage must not fall back")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(cache.entryCount == 0)
    }

    @Test
    func `acquisition cancellation propagates despite verified API usage`() async throws {
        let cache = OpenAIDashboardWebViewCache()
        cache.prepareForTesting = { _, _, _ in throw CancellationError() }
        let fetcher = self.fetcher(cache: cache)
        do {
            _ = try await fetcher.loadLatestDashboard(websiteDataStore: .nonPersistent(), timeout: 2)
            Issue.record("Cancellation must not return API fallback")
        } catch is CancellationError {}
        #expect(cache.entryCount == 0)
        #expect(cache.activeAcquisitionCountForTesting == 0)
    }

    @Test
    func `missing data captures HTML before overall deadline and releases lease`() async throws {
        let cache = OpenAIDashboardWebViewCache()
        cache.prepareForTesting = { webView, _, _ in try await Self.loadFixture(webView) }
        var fetcher = self.fetcher(cache: cache, verified: false, usage: false)
        var capturedHTML: String?
        fetcher.debugArtifactWriterForTesting = { html, _ in capturedHTML = html }
        let started = Date()
        do {
            _ = try await fetcher.loadLatestDashboard(
                websiteDataStore: .nonPersistent(),
                logger: { print("diagnostic: \($0)") },
                debugDumpHTML: true,
                timeout: 3)
            Issue.record("Expected missing dashboard data")
        } catch OpenAIDashboardFetcher.FetchError.noDashboardData {}
        #expect(capturedHTML?.contains("offline-diagnostic-marker") == true)
        #expect(Date().timeIntervalSince(started) < 3.5)
        #expect(cache.entryCount == 0)
        print("PROOF missing data: HTML captured, lease released, elapsed=\(Date().timeIntervalSince(started))")
    }

    @Test(arguments: [false, true])
    func `stalled real WebKit evaluation is bounded and releases lease`(cancel: Bool) async throws {
        let cache = OpenAIDashboardWebViewCache()
        var prepared = false
        cache.prepareForTesting = { webView, _, _ in
            try await Self.loadFixture(webView)
            // A finite local microtask loop stalls subsequent evaluateJavaScript callbacks.
            _ = try await OpenAIWebJavaScript.evaluate(
                """
                setTimeout(() => {
                    const until = Date.now() + 4000;
                    const spin = () => { if (Date.now() < until) Promise.resolve().then(spin); };
                    spin();
                }, 0); true;
                """,
                in: webView,
                deadline: Date().addingTimeInterval(2))
            try await Task.sleep(for: .milliseconds(100))
            prepared = true
        }
        let fetcher = self.fetcher(cache: cache)
        let started = Date()
        let task = Task {
            try await fetcher.loadLatestDashboard(
                websiteDataStore: .nonPersistent(), logger: { print("stalled: \($0)") }, timeout: 2)
        }
        if cancel {
            while !prepared, Date().timeIntervalSince(started) < 1.5 {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
        }
        do {
            let snapshot = try await task.value
            #expect(!cancel)
            #expect(snapshot.creditsRemaining == 42)
        } catch is CancellationError {
            #expect(cancel)
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3)
        #expect(cache.entryCount == 0)
        #expect(cache.activeAcquisitionCountForTesting == 0)
        print("PROOF stalled evaluation: cancel=\(cancel), elapsed=\(elapsed), cache=0, acquisitions=0")
    }

    private static let navigationGuard = OfflineNavigationGuard()

    private static func loadFixture(_ webView: WKWebView) async throws {
        webView.navigationDelegate = self.navigationGuard
        webView.loadHTMLString(
            "<html><body>Select a workspace <p>offline-diagnostic-marker</p></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let data = try await OpenAIWebJavaScript.evaluate(
                "document.body?.innerText ?? ''", in: webView, deadline: deadline)
            if let text = data as? String, text.contains("offline-diagnostic-marker") {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    private final class OfflineNavigationGuard: NSObject, WKNavigationDelegate {
        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
        {
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
#endif
