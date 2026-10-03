import Combine
import XCTest
@testable import Echo

extension XCTestCase {
    @MainActor
    func publishedUsageSnapshot(from store: UsageStore) async -> UsageSnapshot {
        // Wait for write publication first: a newer refresh can suppress older write snapshots.
        let settled = expectation(description: "pending usage writes published")
        let savingSubscription = store.$isSaving
            .first(where: { !$0 })
            .sink { _ in settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        savingSubscription.cancel()

        let published = expectation(description: "usage snapshot refreshed")
        var result: UsageSnapshot?
        let subscription = store.$snapshot
            .dropFirst()
            .first()
            .sink { snapshot in
                result = snapshot
                published.fulfill()
            }
        defer { subscription.cancel() }
        store.refresh()
        await fulfillment(of: [published], timeout: 2)
        return result ?? store.snapshot
    }
}
