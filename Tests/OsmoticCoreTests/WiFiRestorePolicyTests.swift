import Testing
@testable import OsmoticCore

@Suite struct WiFiRestorePolicyTests {
    @Test func acceptsOnlyTheRequestedNetwork() {
        #expect(WiFiRestorePolicy.isCandidate(ssid: "home", expected: "home", camera: "pocket", ip: "192.168.50.43", cameraIP: "192.168.2.69"))
        #expect(!WiFiRestorePolicy.isCandidate(ssid: "other", expected: "home", camera: "pocket", ip: "192.168.50.43", cameraIP: "192.168.2.69"))
        #expect(!WiFiRestorePolicy.isCandidate(ssid: "pocket", expected: nil, camera: "pocket", ip: "192.168.2.69", cameraIP: nil))
    }

    @Test(arguments: [nil, "169.254.3.4", "0.0.0.0", "127.0.0.1", "224.0.0.1", "not-an-ip", "192.168.1", "256.1.1.1", "1.2.invalid.3.4", "1.2..3.4"] as [String?])
    func rejectsUnusableAddresses(_ ip: String?) {
        #expect(!WiFiRestorePolicy.isCandidate(ssid: "home", expected: "home", camera: "pocket", ip: ip, cameraIP: nil))
    }

    @Test func hiddenNetworkMustChangeCameraAddress() {
        #expect(!WiFiRestorePolicy.isCandidate(ssid: nil, expected: "home", camera: "pocket", ip: "192.168.2.69", cameraIP: "192.168.2.69"))
        #expect(WiFiRestorePolicy.isCandidate(ssid: nil, expected: "home", camera: "pocket", ip: "192.168.50.43", cameraIP: "192.168.2.69"))
    }

    @Test func knownHomeCanShareCameraSubnet() {
        #expect(WiFiRestorePolicy.isCandidate(ssid: "home", expected: "home", camera: "pocket", ip: "192.168.2.69", cameraIP: "192.168.2.69"))
    }

    @Test func preservesHomeWhileDHCPOrVPNIsNotReady() {
        for ip in [nil, "169.254.3.4", "192.168.50.43"] as [String?] {
            #expect(WiFiRestorePolicy.shouldPreserveConnection(ssid: "home", camera: "pocket", ip: ip, cameraIP: "192.168.2.69"))
        }
    }

    @Test func preservesManuallySelectedNetwork() {
        #expect(WiFiRestorePolicy.shouldPreserveConnection(ssid: "another-network", camera: "pocket", ip: nil, cameraIP: nil))
        #expect(WiFiRestorePolicy.shouldStopCameraRecovery(ssid: "another-network", camera: "pocket"))
    }

    @Test func permitsRecoveryOnlyWhenNotOnAnotherNetwork() {
        #expect(!WiFiRestorePolicy.shouldPreserveConnection(ssid: "pocket", camera: "pocket", ip: "192.168.2.69", cameraIP: "192.168.2.69"))
        #expect(!WiFiRestorePolicy.shouldPreserveConnection(ssid: nil, camera: "pocket", ip: nil, cameraIP: "192.168.2.69"))
        #expect(!WiFiRestorePolicy.shouldStopCameraRecovery(ssid: "pocket", camera: "pocket"))
        #expect(!WiFiRestorePolicy.shouldStopCameraRecovery(ssid: nil, camera: "pocket"))
        #expect(!WiFiRestorePolicy.shouldStopCameraRecovery(ssid: "", camera: "pocket"))
    }

    @Test func preservesHiddenNetworkOnlyAfterAddressChanges() {
        #expect(WiFiRestorePolicy.shouldPreserveConnection(ssid: nil, camera: "pocket", ip: "192.168.50.43", cameraIP: "192.168.2.69"))
        #expect(!WiFiRestorePolicy.shouldPreserveConnection(ssid: nil, camera: "pocket", ip: "192.168.2.69", cameraIP: "192.168.2.69"))
        #expect(!WiFiRestorePolicy.shouldPreserveConnection(ssid: "", camera: "pocket", ip: "192.168.2.69", cameraIP: "192.168.2.69"))
    }

    @Test func internetFailureDoesNotTriggerWiFiRecovery() {
        #expect(WiFiRestoreResult.connected.wifiRestored)
        #expect(WiFiRestoreResult.internetUnavailable.wifiRestored)
        #expect(!WiFiRestoreResult.notAssociated.wifiRestored)
    }
}
