import Foundation

public enum WiFiRestoreResult: Sendable, Equatable {
    case connected
    case internetUnavailable
    case notAssociated

    public var wifiRestored: Bool { self != .notAssociated }
}

public enum WiFiRestorePolicy {
    public static func shouldPreserveConnection(ssid: String?, camera: String?, ip: String?, cameraIP: String?) -> Bool {
        if let ssid, !ssid.isEmpty { return ssid != camera }
        return isCandidate(ssid: nil, expected: nil, camera: camera, ip: ip, cameraIP: cameraIP)
    }

    public static func shouldStopCameraRecovery(ssid: String?, camera: String) -> Bool {
        guard let ssid, !ssid.isEmpty else { return false }
        return ssid != camera
    }

    public static func isCandidate(
        ssid: String?, expected: String?, camera: String?, ip: String?, cameraIP: String?
    ) -> Bool {
        guard let ip else { return false }
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4, octets[0] != 0, octets[0] != 127, octets[0] < 224,
            !(octets[0] == 169 && octets[1] == 254) else { return false }
        if let ssid, !ssid.isEmpty {
            guard ssid != camera else { return false }
            if let expected { return ssid == expected }
            return true
        }
        if let cameraIP { return ip != cameraIP }
        return !ip.hasPrefix("192.168.2.")
    }
}
