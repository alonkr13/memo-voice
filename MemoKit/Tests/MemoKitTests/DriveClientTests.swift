import Foundation
import Testing
@testable import MemoKit
@testable import MemoCore

private struct StubTokens: TokenProvider {
    func accessToken() async throws -> String { "tok" }
}

/// Records requests and answers them with a scripted handler.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, String)
    nonisolated(unsafe) static var handler: Handler = { _, _ in (500, "") }
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.requests.append((request, body))
        let handler = Self.handler
        Self.lock.unlock()
        let (status, json) = handler(request, body)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset(_ h: @escaping Handler) {
        lock.lock(); handler = h; requests = []; lock.unlock()
    }
}

private final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; defer { n += 1 }; return n }
}

private func query(_ req: URLRequest, _ name: String) -> String? {
    URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == name }?.value
}

// Serialized: the stub's handler and recorded requests are shared static state.
@Suite(.serialized) struct DriveClientTests {
    private func makeClient(protocolClass: AnyClass = StubURLProtocol.self) -> DriveClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [protocolClass]
        let defaults = UserDefaults(suiteName: "drive-\(UUID().uuidString)")!
        return DriveClient(tokens: StubTokens(), session: URLSession(configuration: cfg), defaults: defaults)
    }

    @Test func testEnsureFolderCreatesMissingSegments() async throws {
        StubURLProtocol.reset { req, _ in
            if req.httpMethod == "GET" {
                let q = query(req, "q") ?? ""
                if q.contains("name = 'Memos'") { return (200, #"{"files":[{"id":"MEMOS_ID"}]}"#) }
                return (200, #"{"files":[]}"#)
            }
            return (200, #"{"id":"INBOX_ID"}"#)
        }
        let id = try await makeClient().ensureFolder(path: "Memos/Inbox")
        #expect(id == "INBOX_ID")
        let reqs = StubURLProtocol.requests
        let posts = reqs.filter { $0.0.httpMethod == "POST" }
        #expect(posts.count == 1)
        let body = String(decoding: posts[0].1, as: UTF8.self)
        #expect(body.contains(#""name":"Inbox""#))
        #expect(body.contains(#""parents":["MEMOS_ID"]"#))
        #expect(body.contains("application/vnd.google-apps.folder"))
        // Lookups are scoped to the parent, folders only, and exclude trash.
        let inboxQ = reqs.compactMap { query($0.0, "q") }.first { $0.contains("name = 'Inbox'") } ?? ""
        #expect(inboxQ.contains("'MEMOS_ID' in parents"))
        #expect(inboxQ.contains("trashed=false"))
        #expect(inboxQ.contains("mimeType = 'application/vnd.google-apps.folder'"))
        let memosQ = reqs.compactMap { query($0.0, "q") }.first { $0.contains("name = 'Memos'") } ?? ""
        #expect(memosQ.contains("'root' in parents"))
        #expect(posts[0].0.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func testEnsureFolderCachesResult() async throws {
        StubURLProtocol.reset { req, _ in
            req.httpMethod == "GET" ? (200, #"{"files":[{"id":"X"}]}"#) : (200, #"{"id":"X"}"#)
        }
        let client = makeClient()
        _ = try await client.ensureFolder(path: "A")
        let count = StubURLProtocol.requests.count
        let again = try await client.ensureFolder(path: "A")
        #expect(again == "X")
        #expect(StubURLProtocol.requests.count == count)
    }

    @Test func testEnsureFolderEscapesQuotes() async throws {
        StubURLProtocol.reset { _, _ in (200, #"{"files":[{"id":"F"}]}"#) }
        _ = try await makeClient().ensureFolder(path: "Bob's Notes")
        let q1 = query(StubURLProtocol.requests[0].0, "q") ?? ""
        #expect(q1.contains(#"name = 'Bob\'s Notes'"#))

        StubURLProtocol.reset { _, _ in (200, #"{"files":[{"id":"F"}]}"#) }
        _ = try await makeClient().ensureFolder(path: #"back\slash"#)
        let q2 = query(StubURLProtocol.requests[0].0, "q") ?? ""
        #expect(q2.contains(#"name = 'back\\slash'"#))
    }

    @Test func testUploadSetsAppProperties() async throws {
        let memoId = UUID()
        StubURLProtocol.reset { _, _ in (200, #"{"id":"FILE_ID"}"#) }
        let id = try await makeClient().upload(
            name: "m.md", data: Data("hello".utf8), mimeType: "text/markdown", parent: "P", memoId: memoId)
        #expect(id == "FILE_ID")
        let (req, body) = StubURLProtocol.requests[0]
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""appProperties":{"memoId":"\#(memoId.uuidString)"}"#))
        #expect(text.contains(#""parents":["P"]"#))
        #expect(text.contains("hello"))
        #expect(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/related; boundary=") == true)
        #expect(query(req, "uploadType") == "multipart")
        #expect(query(req, "fields") == "id")
    }

    @Test func testFindFileByMemoId() async throws {
        let memoId = UUID()
        StubURLProtocol.reset { _, _ in (200, #"{"files":[{"id":"FOUND"}]}"#) }
        let found = try await makeClient().findFile(memoId: memoId, parent: "P")
        #expect(found == "FOUND")
        let q = query(StubURLProtocol.requests[0].0, "q") ?? ""
        #expect(q.contains("appProperties has { key='memoId' and value='\(memoId.uuidString)' }"))
        #expect(q.contains("'P' in parents"))

        StubURLProtocol.reset { _, _ in (200, #"{"files":[]}"#) }
        #expect(try await makeClient().findFile(memoId: memoId, parent: "P") == nil)
    }

    @Test func testHttpErrorSurfaced() async throws {
        StubURLProtocol.reset { _, _ in (403, "forbidden") }
        do {
            _ = try await makeClient().upload(
                name: "m.md", data: Data(), mimeType: "text/markdown", parent: "P", memoId: UUID())
            Issue.record("expected throw")
        } catch DriveError.http(let code, let msg) {
            #expect(code == 403)
            #expect(msg == "forbidden")
        }
    }

    @Test func testUnauthorizedSurfaced() async throws {
        StubURLProtocol.reset { _, _ in (401, "expired") }
        do {
            _ = try await makeClient().findFile(memoId: UUID(), parent: "P")
            Issue.record("expected throw")
        } catch DriveError.http(let code, _) {
            #expect(code == 401)
        }
    }

    @Test func testUpload404RecreatesFolderAndRetriesOnce() async throws {
        let counter = Counter()
        StubURLProtocol.reset { req, _ in
            if req.url!.path.hasPrefix("/upload") {
                return counter.next() == 0 ? (404, "gone") : (200, #"{"id":"NEW_FILE"}"#)
            }
            if req.httpMethod == "GET" {
                if (query(req, "q") ?? "").contains("appProperties") { return (200, #"{"files":[]}"#) }
                return (200, #"{"files":[{"id":"FOLDER"}]}"#)
            }
            return (200, #"{"id":"NEWFOLDER"}"#)
        }
        let id = try await makeClient().upload(
            name: "m.md", data: Data("x".utf8), mimeType: "text/markdown", folderPath: "Memos", memoId: UUID())
        #expect(id == "NEW_FILE")
        let uploads = StubURLProtocol.requests.filter { $0.0.url!.path.hasPrefix("/upload") }
        #expect(uploads.count == 2)
        // The folder was resolved twice: once initially, once after the 404 dropped the cache.
        let folderLists = StubURLProtocol.requests.filter {
            $0.0.httpMethod == "GET" && (query($0.0, "q") ?? "").contains("mimeType")
        }
        #expect(folderLists.count == 2)
    }

    @Test func testConvenienceUploadDedupesByMemoId() async throws {
        StubURLProtocol.reset { req, _ in
            if req.httpMethod == "GET" {
                if (query(req, "q") ?? "").contains("appProperties") { return (200, #"{"files":[{"id":"EXISTING"}]}"#) }
                return (200, #"{"files":[{"id":"FOLDER"}]}"#)
            }
            return (200, #"{"id":"SHOULD_NOT_HAPPEN"}"#)
        }
        let id = try await makeClient().upload(
            name: "m.md", data: Data("x".utf8), mimeType: "text/markdown", folderPath: "Memos", memoId: UUID())
        #expect(id == "EXISTING")
        #expect(StubURLProtocol.requests.filter { $0.0.httpMethod == "POST" }.isEmpty)
    }

    /// The .md and .m4a of one memo share a memoId; dedupe must tell them apart by file kind.
    @Test func testConvenienceDedupeDistinguishesFileKinds() async throws {
        let memoId = UUID()
        StubURLProtocol.reset { req, _ in
            if req.url!.path.hasPrefix("/upload") { return (200, #"{"id":"UP"}"#) }
            let q = query(req, "q") ?? ""
            if q.contains("appProperties") {
                return q.contains("key='memoPart' and value='md'")
                    ? (200, #"{"files":[{"id":"MD"}]}"#) : (200, #"{"files":[]}"#)
            }
            return (200, #"{"files":[{"id":"FOLDER"}]}"#)
        }
        let client = makeClient()
        let md = try await client.upload(
            name: "a.md", data: Data("x".utf8), mimeType: "text/markdown", folderPath: "Memos", memoId: memoId)
        #expect(md == "MD")
        #expect(StubURLProtocol.requests.filter { $0.0.url!.path.hasPrefix("/upload") }.isEmpty)

        let audio = try await client.upload(
            name: "a.m4a", data: Data("y".utf8), mimeType: "audio/mp4", folderPath: "Memos", memoId: memoId)
        #expect(audio == "UP")
        let uploads = StubURLProtocol.requests.filter { $0.0.url!.path.hasPrefix("/upload") }
        #expect(uploads.count == 1)
        let body = String(decoding: try #require(uploads.first).1, as: UTF8.self)
        #expect(body.contains(#""memoPart":"m4a""#))
        #expect(body.contains(#""memoId":"\#(memoId.uuidString)""#))
        let finds = StubURLProtocol.requests.compactMap { query($0.0, "q") }.filter { $0.contains("appProperties") }
        #expect(finds.last?.contains("key='memoId' and value='\(memoId.uuidString)'") == true)
        #expect(finds.last?.contains("key='memoPart' and value='m4a'") == true)
    }

    @Test func testDriveErrorsAreDescribed() {
        #expect(DriveError.http(503, "x").localizedDescription.contains("503"))
        #expect(DriveError.notSignedIn.localizedDescription == "Not signed in to Google")
    }

    @Test func testTrashedCachedFolderIsReplaced() async throws {
        StubURLProtocol.reset { req, _ in
            let path = req.url!.path
            if path.hasSuffix("/files/OLD") { return (200, #"{"id":"OLD","trashed":true}"#) }
            if path.hasPrefix("/upload") { return (200, #"{"id":"UP"}"#) }
            if req.httpMethod == "GET" { return (200, #"{"files":[]}"#) }  // no live folder, no existing file
            return (200, #"{"id":"NEWFOLDER"}"#)  // folder create
        }
        let defaults = UserDefaults(suiteName: "drive-\(UUID().uuidString)")!
        defaults.set("OLD", forKey: "memo.drive.folderId.Memos")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let client = DriveClient(tokens: StubTokens(), session: URLSession(configuration: cfg), defaults: defaults)
        let id = try await client.upload(
            name: "m.md", data: Data("x".utf8), mimeType: "text/markdown", folderPath: "Memos", memoId: UUID())
        #expect(id == "UP")
        let upload = StubURLProtocol.requests.first { $0.0.url!.path.hasPrefix("/upload") }!
        #expect(String(decoding: upload.1, as: UTF8.self).contains(#""parents":["NEWFOLDER"]"#))
        #expect(defaults.string(forKey: "memo.drive.folderId.Memos") == "NEWFOLDER")
    }

    @Test func testQueryEncodesPlusAndAmpersand() async throws {
        StubURLProtocol.reset { _, _ in (200, #"{"files":[{"id":"F"}]}"#) }
        _ = try await makeClient().ensureFolder(path: "C++ & a=b#c")
        let raw = StubURLProtocol.requests[0].0.url!.absoluteString
        #expect(raw.contains("%2B"))
        #expect(!raw.contains("+"))
        #expect(raw.contains("%26"))
        #expect(raw.contains("%3D"))
        #expect(raw.contains("%23"))
        #expect((query(StubURLProtocol.requests[0].0, "q") ?? "").contains("name = 'C++ & a=b#c'"))
    }

    @Test func testNetworkErrorMapped() async throws {
        do {
            _ = try await makeClient(protocolClass: FailingURLProtocol.self)
                .findFile(memoId: UUID(), parent: "P")
            Issue.record("expected throw")
        } catch DriveError.network(let e) {
            #expect((e as? URLError)?.code == .notConnectedToInternet)
        }
    }
}

@Suite struct GoogleAuthErrorMappingTests {
    private func isNetwork(_ e: Error) -> Bool { if case DriveError.network = e { return true }; return false }
    private func isNotSignedIn(_ e: Error) -> Bool { if case DriveError.notSignedIn = e { return true }; return false }

    @Test func testURLErrorIsNetwork() {
        #expect(isNetwork(GoogleAuth.map(URLError(.notConnectedToInternet))))
        #expect(isNetwork(GoogleAuth.map(URLError(.timedOut))))
        #expect(isNetwork(GoogleAuth.map(URLError(.networkConnectionLost))))
    }

    @Test func testWrappedNetworkErrorIsNetwork() {
        let inner = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let wrapped = NSError(domain: "org.openid.appauth.general", code: -5,
                              userInfo: [NSUnderlyingErrorKey: inner])
        let outer = NSError(domain: "com.google.GIDSignIn", code: -1, userInfo: [NSUnderlyingErrorKey: wrapped])
        #expect(isNetwork(GoogleAuth.map(outer)))
    }

    @Test func testAuthErrorsAreNotSignedIn() {
        #expect(isNotSignedIn(GoogleAuth.map(NSError(domain: "com.google.GIDSignIn", code: -4))))
        #expect(isNotSignedIn(GoogleAuth.map(
            NSError(domain: "org.openid.appauth.oauth_token", code: -2, userInfo: ["error": "invalid_grant"]))))
    }

    @Test func testUnknownErrorIsNotMisreportedAsSignedOut() {
        let mapped = GoogleAuth.map(NSError(domain: "something.else", code: 7))
        #expect(!isNotSignedIn(mapped))
        #expect(!isNetwork(mapped))
    }
}
