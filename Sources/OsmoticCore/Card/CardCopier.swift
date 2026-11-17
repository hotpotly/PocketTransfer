import Foundation
import CryptoKit

/// Copies a file off the camera's card, reporting progress the way `FileDownloader` does, so the
/// transfer queue behaves the same whether the bytes arrive over Wi-Fi or over the cable.
///
/// A copy in progress lands in `<name>.part` and is moved into place at the end: an interrupted copy
/// (unplugged card, cancel, quit) never leaves a half file looking finished, and the next run starts
/// it again rather than trusting a partial one.
public struct CardCopier: Sendable {
    public enum Outcome: Equatable, Sendable {
        case saved(URL)
        case skipped(URL)
        case failed(String)
        case cancelled
    }

    /// Read in 4 MiB blocks: on a USB 2 card reader that keeps the pipe full without holding much.
    public static let block = 4 << 20

    let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    /// Copies `source` to `destination`, creating its folder. A file already there at the source's
    /// size is left alone (`.skipped`). `progress` gets the bytes written so far.
    public func copy(
        from source: URL, to destination: URL,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async -> Outcome {
        let fm = FileManager.default
        guard let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return .failed("the card no longer has \(source.lastPathComponent)")
        }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed("can't write to \(destination.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        if fm.fileExists(atPath: destination.path) {
            guard (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == size,
                let sourceHash = try? Self.digest(source),
                let destinationHash = try? Self.digest(destination), sourceHash == destinationHash
            else { return .failed("A different file already exists: \(destination.lastPathComponent)") }
            return .skipped(destination)
        }
        let part = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")

        guard fm.createFile(atPath: part.path, contents: nil) else {
            return .failed("can't create \(part.lastPathComponent)")
        }
        do {
            let reader = try FileHandle(forReadingFrom: source)
            let writer = try FileHandle(forWritingTo: part)
            defer {
                try? reader.close()
                try? writer.close()
            }
            var written = 0
            while true {
                if Task.isCancelled {
                    try? fm.removeItem(at: part)
                    return .cancelled
                }
                let chunk = try reader.read(upToCount: Self.block) ?? Data()
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
                written += chunk.count
                progress(written)
            }
            try writer.synchronize()
            guard written == size,
                (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == size
            else {
                try? fm.removeItem(at: part)
                return .failed("The source changed or disconnected during copying.")
            }
            if Task.isCancelled {
                try? fm.removeItem(at: part)
                return .cancelled
            }
            try fm.moveItem(at: part, to: destination)
            log("card: copied \(source.lastPathComponent) (\(written / 1_000_000) MB)")
            return .saved(destination)
        } catch {
            try? fm.removeItem(at: part)
            // A card pulled mid-copy reads as an I/O error: say so plainly, the file is simply not there.
            return .failed(error.localizedDescription)
        }
    }
    private static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: block), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize()
    }

}
