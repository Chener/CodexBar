import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

class AntigravityFallbackStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, URLResponse))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cloudcode.googleapis.com" || request.url?.host == "oauth2.googleapis.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            if let handler = Self.handler {
                let (data, response) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct AntigravityIdentityFallbackTests {
    @Test
    func `403 with provable identity falls back to CLI report`() async throws {
        let registered = URLProtocol.registerClass(AntigravityFallbackStubURLProtocol.self)
        #expect(registered)
        defer {
            if registered {
                URLProtocol.unregisterClass(AntigravityFallbackStubURLProtocol.self)
            }
            AntigravityFallbackStubURLProtocol.handler = nil
        }

        let accountEmail = "provable@example.com"

        // Mock remote 403 behavior
        AntigravityFallbackStubURLProtocol.handler = { request in
            if request.url?.path.contains("/token") == true {
                let data = Data("""
                {
                    "access_token": "fake-token",
                    "expires_in": 3600
                }
                """.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.path.contains("generateCodeAssistUserDiscoveries") == true {
                // Return no plans -> empty codeAssist
                let data = Data("{}".utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.path.contains("fetchAvailableModels") == true {
                // Return empty models
                let data = Data("""
                { "models": [] }
                """.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.path.contains("retrieveUserQuota") == true {
                // 403 Forbidden
                let data = Data("{}".utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            throw URLError(.badURL)
        }

        // Setup tmp home dir for CLI config
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write mock settings.json with the email
        let configDir = tmp.appendingPathComponent(".gemini/antigravity-cli")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let settingsJSON = "{\"accountEmail\": \"\(accountEmail)\"}"
        try settingsJSON.write(to: configDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        // Write a fake binary for `agy -p /usage`
        let binPath = tmp.appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        if [ "$1" = "-p" ] && [ "$2" = "/usage" ]; then
            echo '{"primary": {"usedPercent": 50}, "extraRateWindows": []}'
            exit 0
        fi
        exit 1
        """
        try script.write(to: binPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath.path)

        let env: [String: String] = [
            "HOME": tmp.path,
            "PATH": tmp.path, // So BinaryLocator finds our `agy`
            AntigravityOAuthCredentialsStore.environmentCredentialsKey: """
            {
                "access_token": "fake",
                "refresh_token": "fake",
                "email": "\(accountEmail)"
            }
            """,
        ]

        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            includeOptionalUsage: false,
            requiresOptionalUsageCompleteness: false,
            webTimeout: 10,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: MockUsageFetcher(),
            claudeFetcher: MockClaudeFetcher(),
            browserDetection: BrowserDetection.standard)

        let strategy = AntigravityOAuthFetchStrategy()
        let result = try await strategy.fetch(context)

        #expect(result.sourceLabel == "cli")
        #expect(result.usage.primary?.usedPercent == 50)
        #expect(result.usage.identity?.accountEmail == accountEmail)
        #expect(result.usage.identity?.loginMethod == "cli")
    }

    @Test
    func `403 with unprovable identity maintains Limits not available`() async throws {
        let registered = URLProtocol.registerClass(AntigravityFallbackStubURLProtocol.self)
        #expect(registered)
        defer {
            if registered {
                URLProtocol.unregisterClass(AntigravityFallbackStubURLProtocol.self)
            }
            AntigravityFallbackStubURLProtocol.handler = nil
        }

        let accountEmail = "unprovable@example.com"

        // Mock remote 403 behavior
        AntigravityFallbackStubURLProtocol.handler = { request in
            if request.url?.path.contains("/token") == true {
                let data = Data("""
                {
                    "access_token": "fake-token",
                    "expires_in": 3600
                }
                """.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.path.contains("generateCodeAssistUserDiscoveries") == true {
                let data = Data("{}".utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.path.contains("fetchAvailableModels") == true {
                let data = Data("""
                { "models": [] }
                """.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url?.path.contains("retrieveUserQuota") == true {
                let data = Data("{}".utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            throw URLError(.badURL)
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // We DO NOT write settings.json, so it's unprovable

        let env: [String: String] = [
            "HOME": tmp.path,
            "PATH": tmp.path,
            AntigravityOAuthCredentialsStore.environmentCredentialsKey: """
            {
                "access_token": "fake",
                "refresh_token": "fake",
                "email": "\(accountEmail)"
            }
            """,
        ]

        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            includeOptionalUsage: false,
            requiresOptionalUsageCompleteness: false,
            webTimeout: 10,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: MockUsageFetcher(),
            claudeFetcher: MockClaudeFetcher(),
            browserDetection: BrowserDetection.standard)

        let strategy = AntigravityOAuthFetchStrategy()
        let result = try await strategy.fetch(context)

        #expect(result.sourceLabel == "oauth")
        #expect(result.usage.primary == nil)
        #expect(result.usage.identity?.accountEmail == accountEmail)
        #expect(result.usage.identity?.loginMethod == nil) // CodeAssist is empty, so nil plan
    }
}

/// Minimal mocks for ProviderFetchContext
struct MockUsageFetcher: UsageFetcher {
    func fetch() async throws -> UsageSnapshot { fatalError("stub") }
    func debugCommand() -> CLICommand { fatalError("stub") }
}

struct MockClaudeFetcher: ClaudeUsageFetching {
    func fetch(context: ProviderFetchContext) async throws -> ProviderFetchResult { fatalError("stub") }
}
