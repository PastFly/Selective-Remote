import Foundation
import Testing
@testable import SelectiveRemote

struct UpdateExperienceTests {
    @Test func notificationPolicyNotifiesForANewVersion() {
        #expect(UpdateNotificationPolicy.shouldNotify(
            version: "0.21.5",
            seenVersion: nil,
            lastVersion: "0.21.4",
            lastDate: Date(),
            now: Date()
        ))
    }

    @Test func notificationPolicySuppressesRepeatedNotificationWithinADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!UpdateNotificationPolicy.shouldNotify(
            version: "0.21.5",
            seenVersion: nil,
            lastVersion: "0.21.5",
            lastDate: now.addingTimeInterval(-60 * 60),
            now: now
        ))
    }

    @Test func notificationPolicyAllowsSameVersionAfterADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateNotificationPolicy.shouldNotify(
            version: "0.21.5",
            seenVersion: nil,
            lastVersion: "0.21.5",
            lastDate: now.addingTimeInterval(-(25 * 60 * 60)),
            now: now
        ))
    }

    @Test func notificationPolicySuppressesVersionAlreadySeenInUpdateUI() {
        #expect(!UpdateNotificationPolicy.shouldNotify(
            version: "0.21.5",
            seenVersion: "0.21.5",
            lastVersion: "0.21.4",
            lastDate: nil,
            now: Date()
        ))
    }
}
