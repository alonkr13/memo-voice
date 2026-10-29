import CryptoKit
import Foundation
import Testing
@testable import MemoKit
@testable import MemoCore

@MainActor
@Suite struct ModelManagerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 1 000 bytes; its hash is that of 1 000 zero bytes.
    private let model = WhisperModel(
        id: "test", displayName: "Test", fileName: "ggml-test.bin",
        url: URL(string: "https://example.invalid/ggml-test.bin")!, sizeBytes: 1_000,
        sha256: ModelManagerTests.hex(Data(count: 1_000)))

    @Test func testPartialFileNotDownloaded() throws {
        let dir = try tempDir()
        let manager = ModelManager(modelsDir: dir)
        #expect(!manager.isDownloaded(model))

        // An in-progress .part file is not a model.
        try Data(count: 1_000).write(to: manager.partURL(model))
        #expect(!manager.isDownloaded(model))

        // A truncated file at the final path is not a model either.
        try Data(count: 400).write(to: manager.localURL(model))
        #expect(!manager.isDownloaded(model))

        // Only the complete size counts.
        try Data(count: 1_000).write(to: manager.localURL(model))
        #expect(manager.isDownloaded(model))
    }

    @Test func testFinalizeRejectsWrongSize() throws {
        let dir = try tempDir()
        let tmp = dir.appendingPathComponent("tmp-download")
        try Data(count: 10).write(to: tmp)

        #expect(throws: ModelDownloadError.self) {
            try ModelManager.finalize(downloaded: tmp, model: model, modelsDir: dir, httpStatus: 200)
        }
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(model.fileName).path))
    }

    @Test func testFinalizeRejectsHTTPError() throws {
        let dir = try tempDir()
        let tmp = dir.appendingPathComponent("tmp-download")
        try Data(count: 1_000).write(to: tmp)

        #expect(throws: ModelDownloadError.self) {
            try ModelManager.finalize(downloaded: tmp, model: model, modelsDir: dir, httpStatus: 404)
        }
    }

    @Test func testFinalizeMovesCompleteFile() throws {
        let dir = try tempDir()
        let tmp = dir.appendingPathComponent("tmp-download")
        try Data(count: 1_000).write(to: tmp)

        try ModelManager.finalize(downloaded: tmp, model: model, modelsDir: dir, httpStatus: 200)
        let manager = ModelManager(modelsDir: dir)
        #expect(manager.isDownloaded(model))
        #expect(!FileManager.default.fileExists(atPath: manager.partURL(model).path))
    }

    @Test func testFinalizeRejectsWrongHash() throws {
        let dir = try tempDir()
        let tmp = dir.appendingPathComponent("tmp-download")
        var bytes = Data(count: 1_000)
        bytes[500] = 1   // right size, wrong content
        try bytes.write(to: tmp)

        do {
            try ModelManager.finalize(downloaded: tmp, model: model, modelsDir: dir, httpStatus: 200)
            Issue.record("expected checksum mismatch")
        } catch ModelDownloadError.checksumMismatch {
        }
        let manager = ModelManager(modelsDir: dir)
        #expect(!manager.isDownloaded(model))
        #expect(!FileManager.default.fileExists(atPath: manager.localURL(model).path))
        #expect(!FileManager.default.fileExists(atPath: manager.partURL(model).path))
        #expect(ModelDownloadError.checksumMismatch.errorDescription?.isEmpty == false)
    }

    @Test func testSHA256Streams() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("big")
        // Larger than one read chunk, with non-uniform content.
        let data = Data((0..<(3 * 1_048_576 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: file)
        #expect(try ModelManager.sha256(of: file) == Self.hex(data))
    }

    @Test func testCatalog() {
        let ids = WhisperModel.all.map(\.id)
        #expect(ids == ["ivrit-turbo", "small"])
        #expect(WhisperModel.find(AppSettings().modelId) != nil)
        #expect(WhisperModel.all.allSatisfy { $0.sizeBytes > 100_000_000 })
        let hexDigits = Set("0123456789abcdef")
        #expect(WhisperModel.all.allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy(hexDigits.contains) })
        // Both downloads are pinned to a commit, never a moving branch.
        #expect(WhisperModel.all.allSatisfy { !$0.url.path.contains("/resolve/main/") })
    }
}
