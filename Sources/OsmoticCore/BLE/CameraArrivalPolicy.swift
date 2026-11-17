import Foundation

public struct CameraArrivalPolicy: Sendable {
    private var lastSeen: [UUID: Date] = [:]
    public let absenceInterval: TimeInterval

    public init(absenceInterval: TimeInterval = 90) {
        self.absenceInterval = absenceInterval
    }

    public mutating func observe(_ id: UUID, at now: Date, trusted: Bool, eligible: Bool) -> Bool {
        guard trusted else { return false }
        let previous = lastSeen.updateValue(now, forKey: id)
        return eligible && (previous == nil || now.timeIntervalSince(previous!) >= absenceInterval)
    }

    public mutating func suppress(_ id: UUID, at now: Date) {
        lastSeen[id] = now
    }

    public mutating func expire(at now: Date) -> [UUID] {
        let gone = lastSeen.filter { now.timeIntervalSince($0.value) >= absenceInterval }.map(\.key)
        for id in gone { lastSeen[id] = nil }
        return gone
    }
}
