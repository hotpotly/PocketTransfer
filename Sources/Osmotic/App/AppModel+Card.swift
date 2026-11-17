import AVFoundation
import AppKit
import Foundation
import OsmoticCore

// =========================================================================================
// MARK: The card, over the cable
// =========================================================================================

extension AppModel {
    /// Open a card plugged in over USB: the files come straight off the volume, so there is no
    /// Bluetooth, no Wi-Fi to join and no network to hand back afterwards.
    func openCard(_ card: CardWatcher.Card) {
        guard screen == .cameras, transfer == nil, !readingCard else { return }
        log("=== card \(card.name) [\(card.link?.label ?? "unknown link")] ===")
        cardVolume = card.volume
        cardName = card.name
        cardLink = card.link
        cardFreeBytes = card.freeBytes
        cardTotalBytes = card.totalBytes
        connectError = nil
        lastTransferSummary = nil
        readingCard = true
        Task {
            let volume = card.volume
            let result = await Task.detached(priority: .userInitiated) { CardScanner.files(on: volume) }.value
            files = result
            moreAvailable = false
            selection = []
            cursor = nil
            filter = .all
            workspace = .files
            readingCard = false
            screen = .library
            refreshDownloaded()
            log("card: \(files.count) file(s)")
        }
    }

    /// MB/s measured off the card being browsed, once the probe has run.
    var cardReadSpeed: Double? {
        guard let volume = cardVolume else { return nil }
        return cards.measured[volume]
    }

    /// The reader points at the card themselves. macOS treats picking a folder in an open panel as
    /// consent, so this works even when the removable-volumes permission was refused
    /// (Apple's implied-consent path for files on removable volumes).
    func chooseCard() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Pick the camera's card (the disk with a DCIM folder on it).")
        panel.prompt = String(localized: "Open")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let picked = panel.url else { return }
            self?.openPickedCard(picked)
        }
    }

    private func openPickedCard(_ picked: URL) {
        var volume = picked
        for _ in 0..<4 where !CardScanner.isCameraCard(volume) {
            volume = volume.deletingLastPathComponent()
        }
        guard let card = cards.card(at: volume) else {
            connectError = String(localized: "That disk has no DCIM folder, so there is nothing from a camera on it.")
            return
        }
        openCard(card)
    }

    /// Back to the cameras screen. Nothing to tear down: the card stays mounted for Finder.
    func closeCard(summary: String? = nil) {
        guard isCard else { return }
        if transfer != nil { cancelTransfers() }
        log("card: closed")
        cardVolume = nil
        cardName = ""
        cardLink = nil
        files = []
        selection = []
        cursor = nil
        downloaded = []
        thumbCache.removeAllObjects()
        screen = .cameras
        if let summary { lastTransferSummary = TransferSummary(ok: false, text: summary) }
    }

    /// Eject the card, so the cable can come out without macOS complaining.
    var canEjectCard: Bool {
        guard let volume = cardVolume,
            let values = try? volume.resourceValues(forKeys: [.volumeURLKey, .volumeIsInternalKey]),
            values.volumeIsInternal == false, let root = values.volume
        else { return false }
        return root.standardizedFileURL == volume.standardizedFileURL
    }

    func ejectCard() {
        guard let volume = cardVolume, transfer == nil else { return }
        guard canEjectCard else { closeCard(); return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            log("card: ejected \(cardName)")
            closeCard()
        } catch {
            log("card: eject failed — \(error.localizedDescription)")
            connectError = String(localized: "Couldn’t eject the card. Close anything still reading it and try again.")
        }
    }

    /// The watcher saw the volumes change: if the card being browsed is gone, leave the library.
    func cardsChanged() {
        guard let volume = cardVolume else { return }
        guard let still = cards.cards.first(where: { $0.volume == volume }) else {
            if CardScanner.isCameraCard(volume) { return }
            closeCard(summary: String(localized: "The card was unplugged. What already arrived is saved."))
            return
        }
        cardFreeBytes = still.freeBytes
    }

    /// A frame for the grid: from the clip's small `.LRF` proxy when the camera wrote one, else from
    /// the file itself (a seek, not a read of the whole thing), and photos from their own thumbnail.
    func cardThumbnail(for f: CameraFile) async -> NSImage? {
        guard let volume = cardVolume else { return nil }
        let candidates = [f.proxyPath, f.path].compactMap { $0 }.compactMap { CardScanner.url(for: $0, on: volume) }
        guard !candidates.isEmpty else { return nil }
        let cgImage = await Self.frame(from: candidates, isVideo: f.isVideo)
        let image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        if let image { cacheThumbnail(image, for: f.id) }
        return image
    }

    /// Off the main actor: AVFoundation for clips, Image I/O for stills.
    private nonisolated static func frame(from urls: [URL], isVideo: Bool) async -> CGImage? {
        for url in urls {
            if !isVideo {
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let cg = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 480,
                        ] as CFDictionary)
                {
                    return cg
                }
                continue
            }
            // `.LRF` carries no type macOS knows, so the asset is told what it is.
            let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            if let (cg, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                return cg
            }
        }
        return nil
    }

    /// Copy one file off the card, with the queue's progress reporting.
    func copyFromCard(_ f: CameraFile, to dest: URL) async -> CardCopier.Outcome {
        guard let volume = cardVolume, let source = CardScanner.url(for: f.path, on: volume) else {
            return .failed(String(localized: "The card was unplugged."))
        }
        let sourceRoot = volume.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard !dest.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(sourceRoot) else {
            return .failed(String(localized: "Choose a destination outside the camera."))
        }
        return await copier.copy(from: source, to: dest) { bytes in
            Task { @MainActor [weak self] in self?.transferProgress(fileId: f.id, bytes: bytes) }
        }
    }

    /// The companions next to a clip on the card (`.WAV`, and the `.DNG` beside a JPEG).
    func copyCardSidecars(of f: CameraFile, next dest: URL) async {
        guard let volume = cardVolume else { return }
        for relative in CardScanner.sidecars(of: f, on: volume) {
            guard let source = CardScanner.url(for: relative, on: volume) else { continue }
            let name = CameraFile.safeFileName(source.lastPathComponent)
            let target = dest.deletingLastPathComponent().appendingPathComponent(name)
            let result = await copier.copy(from: source, to: target)
            if case .failed(let reason) = result {
                transfer?.failed.append(source.lastPathComponent)
                log("sidecar: \(source.lastPathComponent) failed: \(reason)")
            }
        }
    }
}
