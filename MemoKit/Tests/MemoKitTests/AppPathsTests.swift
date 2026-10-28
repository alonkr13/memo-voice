import Foundation
import Testing
@testable import MemoKit

@Suite struct AppPathsTests {
    @Test func testFallsBackWhenGroupMissing() throws {
        let paths = AppPaths(groupID: "group.invalid")

        #expect(paths.usingAppGroup == false)

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        #expect(paths.container.standardizedFileURL.path
            .hasPrefix(appSupport.standardizedFileURL.path))

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.audioDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        isDir = false
        #expect(FileManager.default.fileExists(atPath: paths.modelsDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(paths.queueFile.deletingLastPathComponent().standardizedFileURL
            == paths.container.standardizedFileURL)
    }
}
