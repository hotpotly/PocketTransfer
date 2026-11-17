import Foundation

public struct AppStoragePaths: Sendable {
    public let state: URL
    public let downloads: URL

    public init(workspace: URL?, applicationSupport: URL, downloadsDirectory: URL) {
        if let workspace {
            state = workspace.appendingPathComponent("work/runtime", isDirectory: true)
            downloads = workspace.appendingPathComponent("outputs/素材", isDirectory: true)
        } else {
            state = applicationSupport.appendingPathComponent("Pocket Transfer", isDirectory: true)
            downloads = downloadsDirectory.appendingPathComponent("Pocket Transfer", isDirectory: true)
        }
    }
}
