import AppKit
import OsmoticCore

extension AppModel {
    func configureCameraWatch() {
        arrivalNotifier.onImport = { [weak self] id in self?.importFromArrival(id) }
        ble.onSeen = { [weak self] camera in self?.cameraAppeared(camera) }
        setCameraWatch(watchingForCameras)
        cameraWatchTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                ticks += 1
                if ticks % 10 == 0 && self.watchingForCameras {
                    self.notificationPermissionDenied = !(await self.arrivalNotifier.refreshPermission())
                }
                self.updateCameraScanning()
                if self.ble.isScanning {
                    self.ble.pruneStale()
                    self.arrivalNotifier.remove(self.arrivalPolicy.expire(at: Date()))
                }
            }
        }
    }

    func setCameraWatch(_ enabled: Bool) {
        watchingForCameras = enabled
        Preferences.watchForCameras = enabled
        if enabled {
            Task {
                let allowed = await arrivalNotifier.requestPermission()
                notificationPermissionDenied = !allowed
                updateCameraScanning()
            }
        } else {
            arrivalNotifier.remove(savedCameras.map(\.id))
            updateCameraScanning()
        }
    }

    func updateCameraScanning() {
        guard screen == .cameras, !restoringWifi else { ble.stopScan(); return }
        if watchingForCameras || (wirelessEnabled && AppVisibility.shared.visible) {
            ble.startScan()
        } else {
            ble.stopScan()
        }
    }

    private func cameraAppeared(_ camera: DiscoveredCamera) {
        guard watchingForCameras, arrivalNotifier.authorized else { return }
        let trusted = savedCameras.contains { $0.id == camera.id }
        let eligible = watchingForCameras && arrivalNotifier.authorized && screen == .cameras && !restoringWifi
        if arrivalPolicy.observe(camera.id, at: Date(), trusted: trusted, eligible: eligible) {
            arrivalNotifier.arrived(camera.id, name: camera.model.name, folder: Preferences.downloadFolder)
        }
    }

    private func importFromArrival(_ id: UUID) {
        guard watchingForCameras, let saved = savedCameras.first(where: { $0.id == id }) else { return }
        guard screen == .cameras, !restoringWifi, transfer == nil, pendingArrivalImport == nil else {
            connectError = String(localized: "Finish the current connection or import first.")
            return
        }
        arrivalNotifier.remove([id])
        arrivalPolicy.suppress(id, at: Date())
        pendingArrivalImport = id
        Task {
            ble.startScan()
            for _ in 0..<50 {
                guard pendingArrivalImport == id, screen == .cameras else { return }
                if ble.power == .poweredOn { connect(saved: saved); return }
                if ble.power == .unauthorized || ble.power == .poweredOff { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            pendingArrivalImport = nil
            connectError = String(localized: "The Mac’s Bluetooth is off.")
        }
    }

    func finishArrivalConnection(id: UUID, generation: Int) async {
        guard pendingArrivalImport == id else { return }
        await loadOlderWhileNew()
        guard pendingArrivalImport == id, connectGeneration == generation, screen == .library else { return }
        pendingArrivalImport = nil
        refreshDownloaded()
        let fresh = newNotQueued
        guard !fresh.isEmpty else {
            lastTransferSummary = TransferSummary(ok: true, text: String(localized: "No new media to import."))
            await disconnect(keepSummary: true)
            return
        }
        arrivalImportActive = true
        if Preferences.hasChosenDownloadFolder && FileManager.default.isWritableFile(atPath: Preferences.downloadFolder.path) {
            enqueueConfirmed(fresh)
        } else {
            enqueue(fresh, fromArrival: true)
        }
    }
}
