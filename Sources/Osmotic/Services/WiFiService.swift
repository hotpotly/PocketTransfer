import CoreLocation
import CoreWLAN
import Foundation
import Network
import OsmoticCore

/// Moves the Mac's Wi-Fi onto the camera's access point and back.
///
/// The Mac has one Wi-Fi radio, so while the camera's AP is joined the Mac has no Internet over Wi-Fi.
/// Joining uses CoreWLAN, falling back to `networksetup` (which needs no scan and so works even when
/// SSIDs are hidden from the app); restoring uses `networksetup` with the previous network's name,
/// which reads the stored password from the system keychain.
enum WiFiService {
    enum JoinError: LocalizedError {
        case noInterface
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .noInterface: String(localized: "This Mac has no Wi-Fi interface available.")
            case .timedOut(let ssid):
                String(
                    localized:
                        "Couldn’t join the camera’s Wi-Fi network (\(ssid)). Bring the Mac closer to the camera and try again.")
            }
        }
    }

    nonisolated static let cameraIP = "192.168.2.1"

    nonisolated static var interfaceName: String? { CWWiFiClient.shared().interface()?.interfaceName }

    /// The current network's name. Readable only with Location permission (macOS privacy).
    nonisolated static func currentSSID() -> String? { CWWiFiClient.shared().interface()?.ssid() }

    /// Where the Mac ended up on the camera's network — needed later to tell "back home" apart from
    /// "still on the camera", even when home is also a 192.168.2.x network.
    struct Joined: Sendable {
        let interface: String
        let ip: String?
    }

    /// Sleep that ignores task cancellation: restoring the Wi-Fi has to finish even when the task that
    /// asked for it (a cancelled connect, a finished transfer queue) is being torn down.
    nonisolated static func pause(_ seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
        }
    }

    /// Join `ssid` and wait until the camera answers on `192.168.2.1:80`. The AP can take several
    /// seconds to come up after the BLE wake, so this keeps trying until `timeout`.
    nonisolated
    static func join(
        ssid: String, password: String, timeout: TimeInterval = 60,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> Joined {
        guard let iface = CWWiFiClient.shared().interface(), let name = iface.interfaceName else { throw JoinError.noInterface }
        if !iface.powerOn() { try? iface.setPower(true); try await Task.sleep(for: .seconds(2)) }
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        let ipBefore = ipv4Address(name)
        log("wifi: joining \"\(ssid)\" on \(name) (password \(password.count) chars, ip before \(ipBefore ?? "none"))")

        /// On the camera's AP — not merely on some network whose router also answers at 192.168.2.1.
        func onCameraNetwork() -> Bool {
            guard reachable(name) else { return false }
            // With the name readable, the network details are too: an open network is never the camera.
            if let current = iface.ssid() { return current == ssid && iface.security() != .none }
            // Name hidden (no Location permission): trust it only if the address actually changed,
            // or the Mac wasn't on a 192.168.2.x network to begin with.
            guard let ip = ipv4Address(name) else { return false }
            guard let ipBefore else { return true }
            return !ipBefore.hasPrefix("192.168.2.") || ip != ipBefore
        }

        if iface.ssid() == ssid && reachable(name) {
            log("wifi: already on \(ssid)")
            return Joined(interface: name, ip: ipv4Address(name))
        }
        while Date() < deadline {
            try Task.checkCancellation()
            attempt += 1
            var associated = false
            // CoreWLAN first: needs the network visible in a scan.
            if let network = scan(iface, for: ssid) {
                status(String(localized: "Joining \(ssid)…"))
                do {
                    try iface.associate(to: network, password: password)
                    associated = true
                    log("wifi: CoreWLAN associated (attempt \(attempt))")
                } catch {
                    log("wifi: CoreWLAN associate failed: \(error.localizedDescription)")
                }
            } else {
                status(String(localized: "Waiting for the \(ssid) network…"))
                log("wifi: \(ssid) not in scan yet (attempt \(attempt))")
            }
            try Task.checkCancellation()
            // networksetup needs no scan, so it covers SSIDs the scan hides from us. It takes the password
            // as an argument, briefly visible to other local users in `ps` (CWE-214) — so only after
            // CoreWLAN has had a few tries (on the Pocket 3 it joins on the first).
            if !associated && attempt >= 4 {
                let out = runNetworksetup(["-setairportnetwork", name, ssid, password])
                log("wifi: networksetup join → \(out.isEmpty ? "ok" : out)")
            }
            // Wait for DHCP and the camera's web server.
            for _ in 0..<8 {
                try Task.checkCancellation()
                if onCameraNetwork() {
                    let ip = ipv4Address(name)
                    log("wifi: camera reachable at \(cameraIP) (ssid \(iface.ssid() ?? "hidden"), ip \(ip ?? "?"))")
                    checkRoute(expected: name)
                    return Joined(interface: name, ip: ip)
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw JoinError.timedOut(ssid)
    }

    nonisolated private static func scan(_ iface: CWInterface, for ssid: String) -> CWNetwork? {
        do {
            // Exactly this name, and never an open network: an open AP using the camera's name is not
            // the camera.
            let nets = try iface.scanForNetworks(withName: ssid)
            return nets.first { $0.ssid == ssid && !$0.supportsSecurity(.none) }
        } catch {
            log("wifi: scan failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// HTTP downloads follow the system route (only the datalink socket is pinned to Wi-Fi), so a VPN
    /// that captures 192.168.2.0/24 would swallow them. Log where the route really goes.
    nonisolated static func checkRoute(expected: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", cameraIP]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let iface =
            out.split(separator: "\n").first { $0.contains("interface:") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "?"
        if iface == expected {
            log("wifi: route to \(cameraIP) goes via \(iface) ✓")
        } else {
            log(
                "wifi: WARNING route to \(cameraIP) goes via \(iface), not \(expected) — a VPN may be capturing local traffic; downloads can fail"
            )
        }
    }

    nonisolated static func reachable(_ interface: String?) -> Bool {
        TCPProbe.connect(ip: cameraIP, port: 80, timeout: 1.0, interfaceName: interface)
    }

    /// `reachable` off the main actor.
    nonisolated
    static func isCameraReachable() async -> Bool { reachable(interfaceName) }

    @discardableResult nonisolated
    static func restore(previous: String?, cameraSSID: String?, cameraSideIP: String?, forgetCamera: Bool) async -> WiFiRestoreResult {
        guard let iface = CWWiFiClient.shared().interface(), let name = iface.interfaceName else { return .notAssociated }
        if forgetCamera, let cameraSSID, !cameraSSID.isEmpty {
            let out = runNetworksetup(["-removepreferredwirelessnetwork", name, cameraSSID])
            log("wifi: forget camera network → \(out.isEmpty ? "ok" : out.replacingOccurrences(of: cameraSSID, with: "camera"))")
        }
        func preserveCurrentConnection() -> Bool {
            WiFiRestorePolicy.shouldPreserveConnection(
                ssid: iface.ssid(), camera: cameraSSID, ip: ipv4Address(name), cameraIP: cameraSideIP)
        }
        func finishCurrentConnection() async -> WiFiRestoreResult {
            guard await waitForHomeNetwork(iface, name, cameraSSID: cameraSSID, cameraSideIP: cameraSideIP, seconds: 12)
            else {
                log("wifi: non-camera network selected; address not ready; preserving association")
                return .notAssociated
            }
            for attempt in 1...2 {
                let online = await WiFiInternetProbe().check()
                guard WiFiRestorePolicy.isCandidate(
                    ssid: iface.ssid(), expected: nil, camera: cameraSSID, ip: ipv4Address(name), cameraIP: cameraSideIP)
                else { return .notAssociated }
                if online {
                    log("wifi: non-camera network restored; system-route HTTPS verified")
                    return .connected
                }
                if attempt == 1 { await pause(2) }
            }
            log("wifi: Wi-Fi restored; system-route HTTPS unavailable; keeping association and VPN settings")
            return .internetUnavailable
        }
        func joinSaved(_ ssid: String) {
            let out = runNetworksetup(["-setairportnetwork", name, ssid])
            let scrubbed = out.replacingOccurrences(of: ssid, with: redactedSSID(ssid)).replacingOccurrences(of: "\n", with: " ")
            log("wifi: rejoin \(redactedSSID(ssid)) → \(out.isEmpty ? "ok" : scrubbed)")
        }
        if preserveCurrentConnection() { return await finishCurrentConnection() }
        iface.disassociate()
        log("wifi: released camera association; waiting for macOS auto-join")
        _ = await waitForHomeNetwork(iface, name, cameraSSID: cameraSSID, cameraSideIP: cameraSideIP, seconds: 3)
        if preserveCurrentConnection() { return await finishCurrentConnection() }
        if let previous, !previous.isEmpty, previous != cameraSSID {
            for _ in 1...2 {
                if preserveCurrentConnection() { return await finishCurrentConnection() }
                joinSaved(previous)
                _ = await waitForHomeNetwork(iface, name, cameraSSID: cameraSSID, cameraSideIP: cameraSideIP, seconds: 12)
                if preserveCurrentConnection() { return await finishCurrentConnection() }
            }
        } else {
            let visible = Set(((try? iface.scanForNetworks(withSSID: nil)) ?? []).compactMap(\.ssid))
            let preferred = preferredNetworks(name).filter { $0 != cameraSSID }
            let candidates = visible.isEmpty ? Array(preferred.prefix(3)) : Array(preferred.filter(visible.contains).prefix(3))
            for ssid in candidates {
                if preserveCurrentConnection() { return await finishCurrentConnection() }
                joinSaved(ssid)
                _ = await waitForHomeNetwork(iface, name, cameraSSID: cameraSSID, cameraSideIP: cameraSideIP, seconds: 12)
                if preserveCurrentConnection() { return await finishCurrentConnection() }
            }
        }
        log("wifi: no non-camera association verified")
        return .notAssociated
    }

    nonisolated private static func waitForHomeNetwork(
        _ iface: CWInterface, _ interface: String, cameraSSID: String?, cameraSideIP: String?, seconds: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(seconds))
        repeat {
            if WiFiRestorePolicy.isCandidate(
                ssid: iface.ssid(), expected: nil, camera: cameraSSID,
                ip: ipv4Address(interface), cameraIP: cameraSideIP) { return true }
            await pause(1)
        } while Date() < deadline
        return false
    }

    nonisolated static func ipv4Address(_ interface: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(validatingCString: ifa.ifa_name) == interface, let addr = ifa.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }

    /// The Mac's saved Wi-Fi networks, in the system's order.
    nonisolated static func preferredNetworks(_ interface: String? = interfaceName) -> [String] {
        guard let interface else { return [] }
        return runNetworksetup(["-listpreferredwirelessnetworks", interface])
            .split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    nonisolated
    static func isSavedNetwork(_ ssid: String) async -> Bool { preferredNetworks().contains(ssid) }

    /// Run `/usr/sbin/networksetup`; returns trimmed output (empty on success).
    @discardableResult
    nonisolated static func runNetworksetup(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return "failed to run: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Location permission — macOS only reveals Wi-Fi network names to apps that hold it, and the app
/// needs the current network's name to return to it afterwards.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isUndetermined: Bool { manager.authorizationStatus == .notDetermined }

    /// Ask once; returns when the user answers (or right away if they already did).
    func request() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { cont in
            continuation = cont
            manager.requestWhenInUseAuthorization()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.resume()
            }
        }
    }

    private func resume() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.manager.authorizationStatus != .notDetermined { self.resume() }
        }
    }
}

/// Triggers macOS' Local Network permission prompt early (a Bonjour browse is the reliable trigger),
/// so it is answered before the datalink's first UDP packet — which would otherwise be dropped silently
/// while the prompt is up.
@MainActor
enum LocalNetworkPermission {
    private static var browser: NWBrowser?

    static func prime() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_osmotic._udp", domain: nil), using: .udp)
        b.stateUpdateHandler = { state in log("localnet: browser \(state)") }
        b.start(queue: .main)
        browser = b
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            browser?.cancel()
            browser = nil
        }
    }
}
