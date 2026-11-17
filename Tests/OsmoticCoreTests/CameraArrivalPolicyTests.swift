import Foundation
import Testing
@testable import OsmoticCore

@Suite struct CameraArrivalPolicyTests {
    let now = Date(timeIntervalSince1970: 1000)
    let id = UUID()

    @Test func onlyTrustedEligibleCamerasNotify() {
        var policy = CameraArrivalPolicy()
        let unknownIgnored = !policy.observe(id, at: now, trusted: false, eligible: true)
        #expect(unknownIgnored)
        let firstAppearance = policy.observe(id, at: now, trusted: true, eligible: true)
        #expect(firstAppearance)
        let duplicateIgnored = !policy.observe(id, at: now.addingTimeInterval(1), trusted: true, eligible: true)
        #expect(duplicateIgnored)
    }
    @Test func continuousAdvertisementsDoNotSpam() {
        var policy = CameraArrivalPolicy()
        let firstAppearance = policy.observe(id, at: now, trusted: true, eligible: true)
        #expect(firstAppearance)
        for second in 1...1000 {
            let duplicateIgnored = !policy.observe(id, at: now.addingTimeInterval(Double(second)), trusted: true, eligible: true)
            #expect(duplicateIgnored)
        }
    }
    @Test func cameraCanNotifyAgainAfterBeingAbsent() {
        var policy = CameraArrivalPolicy()
        let firstAppearance = policy.observe(id, at: now, trusted: true, eligible: true)
        #expect(firstAppearance)
        let stillNearby = policy.expire(at: now.addingTimeInterval(89)).isEmpty
        #expect(stillNearby)
        let expired = policy.expire(at: now.addingTimeInterval(90)) == [id]
        #expect(expired)
        let reappeared = policy.observe(id, at: now.addingTimeInterval(91), trusted: true, eligible: true)
        #expect(reappeared)
    }
    @Test func disconnectDoesNotImmediatelyNotifyAgain() {
        var policy = CameraArrivalPolicy()
        policy.suppress(id, at: now)
        let disconnectIgnored = !policy.observe(id, at: now.addingTimeInterval(1), trusted: true, eligible: true)
        #expect(disconnectIgnored)
        let busyIgnored = !policy.observe(UUID(), at: now, trusted: true, eligible: false)
        #expect(busyIgnored)
    }
}
