import Foundation
import OsmoticCore

enum RuntimePaths {
    private static let paths = AppStoragePaths(
        workspace: (Bundle.main.object(forInfoDictionaryKey: "PocketTransferWorkspaceRoot") as? String)
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) },
        applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        downloadsDirectory: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])

    static let state = paths.state
    static let downloads = paths.downloads
}
