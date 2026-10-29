import MemoCore
import Foundation

public enum DriveError: Error, LocalizedError {
    case notSignedIn
    case http(Int, String)
    case network(Error)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Google"
        case .http(let code, _): return "Google Drive error (HTTP \(code))"
        case .network(let e): return "Network error: \(e.localizedDescription)"
        }
    }
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

    /// Builds a URL with a strictly percent-encoded query. `URLQueryItem` leaves `+`, `&`, `=`
    /// and `#` alone in values, and Drive decodes `+` as a space, so encode everything but unreserved.
    static func makeURL(_ base: String, _ items: [(String, String)]) -> URL {
        var comps = URLComponents(string: base)!
        comps.percentEncodedQuery = items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        return comps.url!
    }

    static func encode(_ v: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let body = try encoder.encode(Body(name: name, mimeType: Self.folderMime, parents: [parent]))
        var req = URLRequest(url: Self.makeURL(Self.filesURL, [("fields", "id")]))
        req.httpMethod = "POST"
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try decodeID(try await send(req))
    }

    // MARK: Files

    /// Finds a previously uploaded file for this memo (by `appProperties.memoId`, and
    /// `appProperties.memoPart` when `part` is given) in `parent`.
    public func findFile(memoId: UUID, part: String? = nil, parent: String) async throws -> String? {
        var q = "appProperties has { key='memoId' and value='\(memoId.uuidString)' } "
        if let part {
            q += "and appProperties has { key='memoPart' and value='\(Self.escape(part))' } "
        }
        q += "and '\(Self.escape(parent))' in parents and trashed=false"
        return try await listFirst(query: q)
    }

    /// Multipart upload; returns the new file's ID. `part` (e.g. `md`, `m4a`) is stored as
    /// `appProperties.memoPart` so a memo's files can be told apart.
    public func upload(name: String, data: Data, mimeType: String, parent: String, memoId: UUID,
                       part: String? = nil) async throws -> String {
        struct Metadata: Encodable {
            let name: String
            let parents: [String]
            let appProperties: [String: String]
        }
        var props = ["memoId": memoId.uuidString]
        if let part { props["memoPart"] = part }
        let meta = try JSONEncoder().encode(
            Metadata(name: name, parents: [parent], appProperties: props))
        let boundary = "memo-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(meta)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: Self.makeURL(Self.uploadURL, [("uploadType", "multipart"), ("fields", "id")]))
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try decodeID(try await send(req))
    }

    /// Resolves the folder, skips the upload if this memo's file of the same kind (the name's
    /// extension, e.g. `.md` vs `.m4a`) is already in it (dedupe), uploads, and if the folder has
    /// vanished (404) forgets the cache, re-creates the path and retries once.
    public func upload(name: String, data: Data, mimeType: String, folderPath: String, memoId: UUID) async throws -> String {
        let part = Self.part(of: name)
        let parent = try await validatedFolder(path: folderPath)
        if let existing = try await findFile(memoId: memoId, part: part, parent: parent) { return existing }
        do {
            return try await upload(name: name, data: data, mimeType: mimeType, parent: parent,
                                    memoId: memoId, part: part)
        } catch DriveError.http(404, _) {
            forgetFolder(path: folderPath)
            let fresh = try await ensureFolder(path: folderPath)
            return try await upload(name: name, data: data, mimeType: mimeType, parent: fresh,
                                    memoId: memoId, part: part)
        }
    }

    static func part(of name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "file" : ext
    }

    /// Like `ensureFolder`, but a cached ID is checked first: Drive accepts uploads into a trashed
    /// parent, so a trashed (or deleted) cached folder must be dropped and re-resolved.
    private func validatedFolder(path: String) async throws -> String {
        let key = Self.cacheKey(Self.segments(path))
        if let cached = defaults.string(forKey: key) {
            if try await folderIsUsable(id: cached) { return cached }
            defaults.removeObject(forKey: key)
        }
        return try await ensureFolder(path: path)
    }

    private func folderIsUsable(id: String) async throws -> Bool {
        struct Info: Decodable { let trashed: Bool? }
        var req = URLRequest(url: Self.makeURL("\(Self.filesURL)/\(Self.encode(id))", [("fields", "id,trashed")]))
        req.httpMethod = "GET"
        do {
            let data = try await send(req)
            return try JSONDecoder().decode(Info.self, from: data).trashed != true
        } catch DriveError.http(404, _) {
            return false
        }
    }

    // MARK: Plumbing

    private func listFirst(query: String) async throws -> String? {
        struct List: Decodable { struct F: Decodable { let id: String }; let files: [F]? }
        var req = URLRequest(url: Self.makeURL(Self.filesURL, [
            ("q", query), ("fields", "files(id)"), ("spaces", "drive"), ("pageSize", "1")]))
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
