import Foundation
import Testing
@testable import PaymentKit

@Suite("自动刷新时间边界")
struct PaymentAutomaticRefreshTests {
    @Test("无订阅状态的空快照不创建定时任务")
    func emptySnapshotHasNoAutomaticRefreshDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(
            PaymentAutomaticRefreshDeadline.next(in: .empty, after: now) == nil
        )
    }

    @Test("选择交易到期、续订、宽限期和承诺中的最近未来边界")
    func selectsNearestFutureSubscriptionBoundary() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(
            expirationDate: now.addingTimeInterval(40),
            renewalDate: now.addingTimeInterval(30),
            gracePeriodExpirationDate: now.addingTimeInterval(20),
            commitmentRenewalDate: now.addingTimeInterval(10)
        )

        #expect(
            PaymentAutomaticRefreshDeadline.next(in: snapshot, after: now)
                == now.addingTimeInterval(10)
        )
    }

    @Test("忽略已经过去的边界且无未来边界时不创建定时任务")
    func ignoresPastSubscriptionBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeSnapshot(
            expirationDate: now.addingTimeInterval(-1),
            renewalDate: nil,
            gracePeriodExpirationDate: nil,
            commitmentRenewalDate: nil
        )

        #expect(PaymentAutomaticRefreshDeadline.next(in: snapshot, after: now) == nil)
    }

    @Test("默认收敛重试睡眠不继承边界的一秒容差")
    func defaultRetrySleepDoesNotAddBoundaryTolerance() async {
        let clock = PaymentAutomaticRefreshClock()
        let completion = AutomaticRefreshCompletionFlag()
        let task = Task {
            do {
                try await clock.retrySleep(
                    Date().addingTimeInterval(-0.25)
                )
                await completion.markCompleted()
            } catch {
                // 测试清理取消尚未返回的旧实现。
            }
        }
        defer { task.cancel() }

        for _ in 0..<100 where !(await completion.isCompleted) {
            await Task.yield()
        }

        #expect(await completion.isCompleted)
    }

    private func makeSnapshot(
        expirationDate: Date?,
        renewalDate: Date?,
        gracePeriodExpirationDate: Date?,
        commitmentRenewalDate: Date?
    ) -> PaymentSnapshot {
        let transaction = PaymentTransaction(
            id: 1,
            originalID: 1,
            productID: "subscription",
            subscriptionGroupID: "subscription-group",
            productType: .autoRenewableSubscription,
            purchaseDate: Date(timeIntervalSince1970: 0),
            originalPurchaseDate: Date(timeIntervalSince1970: 0),
            expirationDate: expirationDate,
            revocationDate: nil,
            signedDate: Date(timeIntervalSince1970: 0),
            ownershipType: .purchased,
            purchasedQuantity: 1,
            appAccountToken: nil,
            isUpgraded: false,
            jwsRepresentation: "transaction-jws"
        )
        let renewalInfo = PaymentRenewalInfo(
            originalTransactionID: 1,
            currentProductID: "subscription",
            willAutoRenew: true,
            autoRenewPreference: "subscription",
            expirationReason: nil,
            priceIncreaseStatus: .noIncreasePending,
            isInBillingRetry: false,
            gracePeriodExpirationDate: gracePeriodExpirationDate,
            renewalDate: renewalDate,
            renewalPrice: nil,
            currencyCode: nil,
            jwsRepresentation: "renewal-jws",
            commitment: commitmentRenewalDate.map { renewalDate in
                PaymentRenewalCommitment(
                    autoRenewPreference: "subscription",
                    renewalBillingPlan: .monthlyCommitment,
                    renewalDate: renewalDate,
                    renewalPrice: 9.99,
                    willAutoRenew: true
                )
            }
        )

        return PaymentSnapshot(
            subscriptionStatuses: [
                PaymentSubscriptionStatus(
                    groupID: "subscription-group",
                    state: .subscribed,
                    transaction: transaction,
                    renewalInfo: renewalInfo
                )
            ]
        )
    }
}

private actor AutomaticRefreshCompletionFlag {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}
