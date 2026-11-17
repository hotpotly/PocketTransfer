import Foundation
import Testing
@testable import OsmoticCore

@Suite struct AppStoragePathsTests {
    private let support = URL(fileURLWithPath: "/example/Library/Application Support", isDirectory: true)
    private let downloads = URL(fileURLWithPath: "/example/Downloads", isDirectory: true)

    @Test func publicBuildUsesUserDirectories() {
        let paths = AppStoragePaths(workspace: nil, applicationSupport: support, downloadsDirectory: downloads)
        #expect(paths.state.path == "/example/Library/Application Support/Pocket Transfer")
        #expect(paths.downloads.path == "/example/Downloads/Pocket Transfer")
        #expect(!paths.state.path.contains("Applications/"))
    }

    @Test func workspaceBuildPreservesExistingDataLocations() {
        let paths = AppStoragePaths(workspace: URL(fileURLWithPath: "/project"), applicationSupport: support, downloadsDirectory: downloads)
        #expect(paths.state.path == "/project/work/runtime")
        #expect(paths.downloads.path == "/project/outputs/素材")
    }

    @Test func userDirectoriesAreNotHardcoded() {
        let paths = AppStoragePaths(workspace: nil, applicationSupport: URL(fileURLWithPath: "/another/support"), downloadsDirectory: URL(fileURLWithPath: "/another/downloads"))
        #expect(paths.state.path == "/another/support/Pocket Transfer")
        #expect(paths.downloads.path == "/another/downloads/Pocket Transfer")
    }
}
