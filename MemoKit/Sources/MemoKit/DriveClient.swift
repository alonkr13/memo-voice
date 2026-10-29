import Foundation

public enum DriveError: Error {
    case notSignedIn
    case http(Int, String)
    case network(Error)
}

public protocol TokenProvider: Sendable {
    func accessToken() async throws -> String
}

/// Minimal Google Drive v3 REST client (drive.file scope). Independent of GoogleSignIn:
/// it only needs a `TokenProvider`, so tests can stub both the token and the network.
public final class DriveClient: @unchecked Sendable {
    private let tokens: TokenProvider
    private let session: URLSession
    private let defaults: UserDefaults

    private static let filesURL = "https://www.googleapis.com/drive/v3/files"
    private static let uploadURL = "https://www.googleapis.com/upload/drive/v3/files"
    private static let folderMime = "application/vnd.google-apps.folder"

    public init(tokens: TokenProvider, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.tokens = tokens
        self.session = session
        self.defaults = defaults
    }

    // MARK: Folders

    /// Resolves (creating missing segments) a folder path such as `Memos/Inbox` and returns its ID.
    public func ensureFolder(path: String) async throws -> String {
        let segments = Self.segments(path)
        let key = Self.cacheKey(segments)
        if let cached = defaults.string(forKey: key) { return cached }

        var parent = "root"
        for name in segments {
            if let existing = try await findFolder(name: name, parent: parent) {
                parent = existing
            } else {
                parent = try await createFolder(name: name, parent: parent)
            }
        }
        defaults.set(parent, forKey: key)
        return parent
    }

    /// Drops the cached folder ID for a path (e.g. after the folder was deleted in Drive).
    public func forgetFolder(path: String) {
        defaults.removeObject(forKey: Self.cacheKey(Self.segments(path)))
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func cacheKey(_ segments: [String]) -> String {
        "memo.drive.folderId." + segments.joined(separator: "/")
    }

    /// Escapes a value for use inside a single-quoted Drive query string.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func findFolder(name: String, parent: String) async throws -> String? {
        let q = "name = '\(Self.escape(name))' and mimeType = '\(Self.folderMime)' "
            + "and '\(Self.escape(parent))' in parents and trashed=false"
        return try await listFirst(query: q)
    }

    private func createFolder(name: String, parent: String) async throws -> String {
        struct Body: Encodable { let name: String; let mimeType: String; let parents: [String] }
        let body = try JSONEncoder().encode(Body(name: name, mimeType: Self.folderMime, parents: [parent]))
        var comps = URLComponents(string: Self.filesURL)!
        comps.queryItems = [URLQueryItem(name: "fields", value: "id")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try decodeID(try await send(req))
    }

    // MARK: Files

    /// Finds a previously uploaded file for this memo (by `appProperties.memoId`) in `parent`.
    public func findFile(memoId: UUID, parent: String) async throws -> String? {
        let q = "appProperties has { key='memoId' and value='\(memoId.uuidString)' } "
            + "and '\(Self.escape(parent))' in parents and trashed=false"
        return try await listFirst(query: q)
    }

    /// Multipart upload; returns the new file's ID.
    public func upload(name: String, data: Data, mimeType: String, parent: String, memoId: UUID) async throws -> String {
        struct Metadata: Encodable {
            let name: String
            let parents: [String]
            let appProperties: [String: String]
        }
        let meta = try JSONEncoder().encode(
            Metadata(name: name, parents: [parent], appProperties: ["memoId": memoId.uuidString]))
        let boundary = "memo-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(meta)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var comps = URLComponents(string: Self.uploadURL)!
        comps.queryItems = [URLQueryItem(name: "uploadType", value: "multipart"),
                            URLQueryItem(name: "fields", value: "id")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try decodeID(try await send(req))
    }

    /// Ensures the folder, uploads, and if the cached folder has vanished (404) forgets the
    /// cache, re-creates the path and retries once.
    public func upload(name: String, data: Data, mimeType: String, folderPath: String, memoId: UUID) async throws -> String {
        let parent = try await ensureFolder(path: folderPath)
        do {
            return try await upload(name: name, data: data, mimeType: mimeType, parent: parent, memoId: memoId)
        } catch DriveError.http(404, _) {
            forgetFolder(path: folderPath)
            let fresh = try await ensureFolder(path: folderPath)
            return try await upload(name: name, data: data, mimeType: mimeType, parent: fresh, memoId: memoId)
        }
    }

    // MARK: Plumbing

    private func listFirst(query: String) async throws -> String? {
        struct List: Decodable { struct F: Decodable { let id: String }; let files: [F]? }
        var comps = URLComponents(string: Self.filesURL)!
        comps.queryItems = [URLQueryItem(name: "q", value: query),
                            URLQueryItem(name: "fields", value: "files(id)"),
                            URLQueryItem(name: "spaces", value: "drive"),
                            URLQueryItem(name: "pageSize", value: "1")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let data = try await send(req)
        return try JSONDecoder().decode(List.self, from: data).files?.first?.id
    }

    private func decodeID(_ data: Data) throws -> String {
        struct R: Decodable { let id: String }
        return try JSONDecoder().decode(R.self, from: data).id
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        let token = try await tokens.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw DriveError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriveError.http(-1, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DriveError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
