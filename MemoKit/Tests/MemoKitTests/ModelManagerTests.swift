import Foundation
import Testing
@testable import MemoKit

@MainActor
@Suite struct ModelManagerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let model = WhisperModel(
        id: "test", displayName: "Test", fileName: "ggml-test.bin",
        url: URL(string: "https://example.invalid/ggml-test.bin")!, sizeBytes: 1_000)

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

    @Test func testCatalog() {
        let ids = WhisperModel.all.map(\.id)
        #expect(ids == ["ivrit-turbo", "small"])
        #expect(WhisperModel.find(AppSettings().modelId) != nil)
        #expect(WhisperModel.all.allSatisfy { $0.sizeBytes > 100_000_000 })
    }
}
