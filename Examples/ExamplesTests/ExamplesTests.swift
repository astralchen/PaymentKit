import Foundation
@_spi(Testing) import PaymentKit
import StoreKit
import StoreKitTest
import Testing
import XCTest
@testable import Examples

@Suite("PaymentKit StoreKit 本地集成测试", .serialized)
struct PaymentKitStoreKitTests {
    private let productIDs = [
        "paymentkit.demo.coins100",
        "paymentkit.demo.lifetime",
        "paymentkit.demo.monthly",
        "paymentkit.demo.yearly",
    ]

    @Test("StoreKit 配置文件结构完整")
    func storeKitConfigurationIsValid() throws {
        let url = try #require(
            Bundle.main.url(forResource: "PaymentKit", withExtension: "storekit")
        )
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let products = root["products"] as? [[String: Any]] ?? []
        let nonRenewing = root["nonRenewingSubscriptions"] as? [[String: Any]] ?? []
        let groups = root["subscriptionGroups"] as? [[String: Any]] ?? []
        let subscriptions = groups.flatMap {
            $0["subscriptions"] as? [[String: Any]] ?? []
        }
        let allProducts = products + nonRenewing + subscriptions
        let settings = try #require(root["settings"] as? [String: Any])
        #expect(settings["_locale"] as? String == "zh_Hans")
        #expect(settings["_storefront"] as? String == "CHN")
        let typesByID: [String: String] = Dictionary(
            uniqueKeysWithValues: allProducts.compactMap { product -> (String, String)? in
                guard
                    let productID = product["productID"] as? String,
                    let type = product["type"] as? String
                else { return nil }
                return (productID, type)
            }
        )

        // 独立解析配置文件，避免 StoreKit CLI 故障掩盖商品或订阅组配置回归。
        #expect(Set(typesByID.keys) == Set(productIDs))
        #expect(typesByID[productIDs[0]] == "Consumable")
        #expect(typesByID[productIDs[1]] == "NonConsumable")
        #expect(typesByID[productIDs[2]] == "RecurringSubscription")
        #expect(typesByID[productIDs[3]] == "RecurringSubscription")
        #expect(nonRenewing.isEmpty)
        #expect(groups.count == 1)
        #expect(Set(subscriptions.compactMap { $0["subscriptionGroupID"] as? String }).count == 1)

        let productsByID = Dictionary(
            uniqueKeysWithValues: products.compactMap { product -> (String, [String: Any])? in
                guard let productID = product["productID"] as? String else { return nil }
                return (productID, product)
            }
        )
        let coins = try #require(productsByID[productIDs[0]])
        #expect(coins["referenceName"] as? String == "PaymentKit Coins 100")
        #expect(coins["displayPrice"] as? String == "8")
        #expect((coins["localizations"] as? [[String: Any]])?.count == 1)
        let coinsLocalization = try #require(
            (coins["localizations"] as? [[String: Any]])?.first
        )
        #expect(coinsLocalization["locale"] as? String == "zh_Hans")
        #expect(coinsLocalization["displayName"] as? String == "100 个演示代币")
        #expect(
            coinsLocalization["description"] as? String
                == "用于验证消耗型 App 内购买流程的演示商品。"
        )

        let lifetime = try #require(productsByID[productIDs[1]])
        #expect(lifetime["referenceName"] as? String == "PaymentKit Lifetime")
        #expect(lifetime["displayPrice"] as? String == "8")
        #expect(lifetime["familyShareable"] as? Bool == true)
        #expect((lifetime["localizations"] as? [[String: Any]])?.count == 1)
        let lifetimeLocalization = try #require(
            (lifetime["localizations"] as? [[String: Any]])?.first
        )
        #expect(lifetimeLocalization["locale"] as? String == "zh_Hans")
        #expect(lifetimeLocalization["displayName"] as? String == "永久解锁")
        #expect(
            lifetimeLocalization["description"] as? String
                == "用于验证非消耗型 App 内购买流程的演示商品。"
        )

        let group = try #require(groups.first)
        #expect(group["id"] as? String == "22255725")
        #expect(group["name"] as? String == "PaymentKit Demo Subscription")
        let groupLocalization = try #require(
            (group["localizations"] as? [[String: Any]])?.first
        )
        #expect(groupLocalization["displayName"] as? String == "PaymentKit 演示订阅")

        let subscriptionsByID = Dictionary(
            uniqueKeysWithValues: subscriptions.compactMap { subscription -> (String, [String: Any])? in
                guard let productID = subscription["productID"] as? String else { return nil }
                return (productID, subscription)
            }
        )
        let monthly = try #require(subscriptionsByID[productIDs[2]])
        #expect(monthly["referenceName"] as? String == "PaymentKit Monthly")
        #expect(monthly["displayPrice"] as? String == "22")
        #expect(monthly["groupNumber"] as? Int == 2)
        #expect(monthly["subscriptionGroupID"] as? String == "22255725")
        #expect(monthly["familyShareable"] as? Bool == true)
        let monthlyLocalizations = try #require(
            monthly["localizations"] as? [[String: Any]]
        )
        let monthlyLocalizationsByLocale = Dictionary(
            uniqueKeysWithValues: monthlyLocalizations.compactMap {
                localization -> (String, [String: Any])? in
                guard let locale = localization["locale"] as? String else { return nil }
                return (locale, localization)
            }
        )
        #expect(Set(monthlyLocalizationsByLocale.keys) == ["zh_Hans", "en_US"])
        #expect(monthlyLocalizationsByLocale["zh_Hans"]?["displayName"] as? String == "月订阅")
        #expect(
            monthlyLocalizationsByLocale["zh_Hans"]?["description"] as? String
                == "用于验证自动续期订阅流程的演示月订阅。"
        )
        #expect(
            monthlyLocalizationsByLocale["en_US"]?["displayName"] as? String
                == "Monthly Subscription"
        )
        #expect(
            monthlyLocalizationsByLocale["en_US"]?["description"] as? String
                == "A demo monthly auto-renewable subscription."
        )
        let monthlyOffer = try #require(monthly["introductoryOffer"] as? [String: Any])
        #expect(monthlyOffer["paymentMode"] as? String == "free")
        #expect(monthlyOffer["subscriptionPeriod"] as? String == "P1W")
        #expect(monthlyOffer["numberOfPeriods"] as? Int == 1)
        #expect((monthly["introductoryOffers"] as? [[String: Any]])?.count == 1)
        let monthlyPromotionalOffers = try #require(
            monthly["adHocOffers"] as? [[String: Any]]
        )
        let monthlyPromotionalOffer = try #require(monthlyPromotionalOffers.first)
        #expect(monthlyPromotionalOffers.count == 1)
        #expect(
            monthlyPromotionalOffer["offerID"] as? String
                == "pk_monthly_promo_099_2m_2026"
        )
        #expect(monthlyPromotionalOffer["displayPrice"] as? String == "8")
        #expect(monthlyPromotionalOffer["paymentMode"] as? String == "payAsYouGo")
        #expect(monthlyPromotionalOffer["subscriptionPeriod"] as? String == "P1M")
        #expect(monthlyPromotionalOffer["numberOfPeriods"] as? Int == 2)

        let monthlyWinBackOffers = try #require(
            monthly["winbackOffers"] as? [[String: Any]]
        )
        #expect(monthlyWinBackOffers.isEmpty)

        let annual = try #require(subscriptionsByID[productIDs[3]])
        #expect(annual["referenceName"] as? String == "PaymentKit Yearly")
        #expect(annual["displayPrice"] as? String == "198")
        #expect(annual["groupNumber"] as? Int == 1)
        #expect(annual["subscriptionGroupID"] as? String == "22255725")
        #expect(annual["familyShareable"] as? Bool == true)
        let annualLocalizations = try #require(
            annual["localizations"] as? [[String: Any]]
        )
        let annualLocalizationsByLocale = Dictionary(
            uniqueKeysWithValues: annualLocalizations.compactMap {
                localization -> (String, [String: Any])? in
                guard let locale = localization["locale"] as? String else { return nil }
                return (locale, localization)
            }
        )
        #expect(Set(annualLocalizationsByLocale.keys) == ["zh_Hans", "en_US"])
        #expect(annualLocalizationsByLocale["zh_Hans"]?["displayName"] as? String == "年订阅")
        #expect(
            annualLocalizationsByLocale["zh_Hans"]?["description"] as? String
                == "用于验证自动续期订阅流程的演示年订阅。"
        )
        #expect(
            annualLocalizationsByLocale["en_US"]?["displayName"] as? String
                == "Yearly Subscription"
        )
        #expect(
            annualLocalizationsByLocale["en_US"]?["description"] as? String
                == "A demo yearly auto-renewable subscription."
        )
        let annualOffer = try #require(annual["introductoryOffer"] as? [String: Any])
        #expect(annualOffer["paymentMode"] as? String == "payUpFront")
        #expect(annualOffer["subscriptionPeriod"] as? String == "P1Y")
        #expect(annualOffer["numberOfPeriods"] as? Int == 1)
        #expect(annualOffer["displayPrice"] as? String == "148")
        #expect((annual["introductoryOffers"] as? [[String: Any]])?.count == 1)
        let annualCodeOffers = try #require(
            annual["codeOffers"] as? [[String: Any]]
        )
        let annualCodeOffer = try #require(annualCodeOffers.first)
        #expect(annualCodeOffers.count == 1)
        #expect(
            annualCodeOffer["referenceName"] as? String
                == "pk_annual_code_999_2026"
        )
        #expect(annualCodeOffer["displayPrice"] as? String == "68")
        #expect(annualCodeOffer["paymentMode"] as? String == "payUpFront")
        #expect(annualCodeOffer["subscriptionPeriod"] as? String == "P1Y")
        #expect(
            Set(annualCodeOffer["eligibility"] as? [String] ?? [])
                == ["new", "existing", "expired"]
        )

        let annualBillingPlans = try #require(
            annual["billingPlans"] as? [[String: Any]]
        )
        #expect(annualBillingPlans.count == 2)
        #expect(
            Set(annualBillingPlans.compactMap { $0["billingPlanType"] as? String })
                == ["BILLED_UPFRONT", "MONTHLY"]
        )
        let monthlyCommitmentPlan = try #require(
            annualBillingPlans.first {
                $0["billingPlanType"] as? String == "MONTHLY"
            }
        )
        #expect(monthlyCommitmentPlan["displayPrice"] as? String == "18")
        #expect(
            monthlyCommitmentPlan["commitmentDisplayPrice"] as? String == "216"
        )

        let version = try #require(root["version"] as? [String: Int])
        #expect(version == ["major": 5, "minor": 0])
    }

    @Test("示例同时展示当前订阅商品和下一期续订偏好")
    func exampleDisplaysCurrentAndNextSubscriptionProducts() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // 示例必须直接展示两个 StoreKit 字段，才能人工区分升级、降级和普通续订。
        #expect(source.contains("status.renewalInfo.currentProductID"))
        #expect(source.contains("status.renewalInfo.autoRenewPreference"))
    }

    @Test("关闭自动续订时不展示残留续订偏好")
    func disabledAutoRenewIgnoresResidualPreference() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/ContentView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Sandbox 可能短暂返回 false 与非空 preference；展示必须以 willAutoRenew 为准。
        #expect(source.contains("if status.renewalInfo.willAutoRenew,"))
    }

    @Test("月付承诺取消后区分剩余分期和下一承诺续期")
    func distinguishesCommitmentCancellationFromInstallmentRenewal() {
        let renewalInfo = PaymentRenewalInfo(
            originalTransactionID: 1,
            currentProductID: "paymentkit.demo.yearly",
            willAutoRenew: true,
            autoRenewPreference: "paymentkit.demo.yearly",
            expirationReason: nil,
            priceIncreaseStatus: .noIncreasePending,
            isInBillingRetry: false,
            gracePeriodExpirationDate: nil,
            renewalDate: nil,
            renewalPrice: 18,
            currencyCode: "CNY",
            jwsRepresentation: "header.payload.signature",
            renewalBillingPlan: .monthlyCommitment,
            commitment: PaymentRenewalCommitment(
                autoRenewPreference: "paymentkit.demo.yearly",
                renewalBillingPlan: .monthlyCommitment,
                renewalDate: Date(timeIntervalSince1970: 1_800_000_000),
                renewalPrice: 18,
                willAutoRenew: false
            )
        )
        let transactionCommitment = PaymentTransactionCommitment(
            billingPeriodNumber: 11,
            totalBillingPeriods: 12,
            expirationDate: Date(timeIntervalSince1970: 1_800_000_000),
            price: 18
        )

        let presentation = SubscriptionRenewalPresentation(
            renewalInfo: renewalInfo,
            transactionCommitment: transactionCommitment
        )

        #expect(presentation.periodStatus == "当前承诺：剩余 1 期继续按月付款")
        #expect(presentation.commitmentStatus == "下一承诺：已取消")
        #expect(presentation.progressStatus == "承诺进度：第 11/12 期")
    }

    @Test("月付承诺最后一期不显示不存在的下一分期")
    func completesCurrentCommitmentWithoutInventingInstallment() {
        let renewalInfo = PaymentRenewalInfo(
            originalTransactionID: 3,
            currentProductID: "paymentkit.demo.yearly",
            willAutoRenew: false,
            autoRenewPreference: nil,
            expirationReason: nil,
            priceIncreaseStatus: .noIncreasePending,
            isInBillingRetry: false,
            gracePeriodExpirationDate: nil,
            renewalDate: nil,
            renewalPrice: 18,
            currencyCode: "CNY",
            jwsRepresentation: "header.payload.signature",
            renewalBillingPlan: .monthlyCommitment,
            commitment: PaymentRenewalCommitment(
                autoRenewPreference: "paymentkit.demo.yearly",
                renewalBillingPlan: .monthlyCommitment,
                renewalDate: Date(timeIntervalSince1970: 1_800_000_000),
                renewalPrice: 18,
                willAutoRenew: false
            )
        )
        let transactionCommitment = PaymentTransactionCommitment(
            billingPeriodNumber: 12,
            totalBillingPeriods: 12,
            expirationDate: Date(timeIntervalSince1970: 1_800_000_000),
            price: 18
        )

        let presentation = SubscriptionRenewalPresentation(
            renewalInfo: renewalInfo,
            transactionCommitment: transactionCommitment
        )

        #expect(presentation.periodStatus == "当前承诺：全部分期已完成")
        #expect(presentation.commitmentStatus == "下一承诺：已取消")
        #expect(presentation.progressStatus == "承诺进度：第 12/12 期")
    }

    @Test("普通订阅仍使用自动续订文案")
    func preservesStandardSubscriptionRenewalPresentation() {
        let renewalInfo = PaymentRenewalInfo(
            originalTransactionID: 2,
            currentProductID: "paymentkit.demo.monthly",
            willAutoRenew: false,
            autoRenewPreference: "paymentkit.demo.monthly",
            expirationReason: nil,
            priceIncreaseStatus: .noIncreasePending,
            isInBillingRetry: false,
            gracePeriodExpirationDate: nil,
            renewalDate: nil,
            renewalPrice: 22,
            currencyCode: "CNY",
            jwsRepresentation: "header.payload.signature"
        )

        let presentation = SubscriptionRenewalPresentation(
            renewalInfo: renewalInfo,
            transactionCommitment: nil
        )

        #expect(presentation.periodStatus == "不会自动续订")
        #expect(presentation.commitmentStatus == nil)
        #expect(presentation.progressStatus == nil)
    }

    @Test("系统界面关闭后自动协调 StoreKit 状态")
    func refreshesAfterEveryStoreKitPresentation() throws {
        let source = try exampleModelSource()

        #expect(method("showManageSubscriptions", in: source).contains(
            "reconcileAfterStoreKitPresentation"
        ))
        #expect(method("redeemOfferCode", in: source).contains(
            "reconcileAfterStoreKitPresentation"
        ))
        #expect(method("display", in: source).contains(
            "reconcileAfterStoreKitPresentation"
        ))
        #expect(method("requestRefund", in: source).contains(
            "reconcileAfterStoreKitPresentation"
        ))
        for methodName in [
            "showManageSubscriptions",
            "redeemOfferCode",
            "display",
            "requestRefund",
        ] {
            #expect(method(methodName, in: source).contains(
                "performStoreKitPresentation"
            ))
        }
        let reconciliation = method("reconcileAfterStoreKitPresentation", in: source)
        #expect(reconciliation.contains("StoreKitPresentationReconciler"))
        #expect(reconciliation.contains("client.reloadStoreSession()"))
        #expect(reconciliation.contains("reloadBackendSnapshot()"))
        #expect(!reconciliation.contains("restorePurchases"))
        #expect(!reconciliation.contains("AppStore.sync"))
    }

    @Test("交易监听事件自动刷新共享模拟后台快照")
    func reloadsBackendAfterExternalTransactionEvent() throws {
        let source = try exampleModelSource()
        let modelStart = try #require(
            source.range(of: "final class PaymentKitExampleModel")
        )
        let modelSource = String(source[modelStart.lowerBound...])
        let receiver = method("receive(_ event:", in: modelSource)

        #expect(receiver.contains("ExamplePaymentEventReceiver"))
        #expect(receiver.contains("await receiver.receive(event)"))
        #expect(method("startIfNeeded", in: modelSource).contains("await self?.receive(event)"))
    }

    @Test("购买、恢复和订阅管理 UI 验收不点击诊断刷新按钮")
    func automaticUIFlowsNeverTapDiagnosticRefresh() throws {
        let source = try examplesUITestSource()
        let workflows = [
            (
                method: "testPurchaseConvergesWithoutManualRefresh",
                action: "purchase-paymentkit.demo.coins100",
                expectedState: "交易已交付并 finish："
            ),
            (
                method: "testRestoreConvergesWithoutManualRefresh",
                action: "restore-button",
                expectedState: "App Store 同步与恢复已完成"
            ),
            (
                method: "testManageSubscriptionsReturnConvergesWithoutManualRefresh",
                action: "manage-subscriptions-button",
                expectedState: "不会自动续订"
            ),
        ]

        for workflow in workflows {
            let body = method(workflow.method, in: source)
            #expect(body.contains(workflow.action))
            #expect(body.contains(workflow.expectedState))
            #expect(body.contains("waitForLabel"))
            #expect(!body.contains("refresh-button"))
        }

        // 诊断按钮可以继续存在于示例 UI，但生产流程测试不得借助它制造假绿结果。
        #expect(!source.contains("app.buttons[\"refresh-button\"].tap()"))

        let restoreBody = method("testRestoreConvergesWithoutManualRefresh", in: source)
        #expect(
            restoreBody.components(
                separatedBy: "assertRestorableLifetimeEntitlement"
            ).count - 1 == 2,
            "恢复前必须验证账号已有永久解锁，恢复后必须再次验证同一权益仍然收敛"
        )
        #expect(
            method("assertRestorableLifetimeEntitlement", in: source).contains(
                "entitlement-paymentkit.demo.lifetime"
            ),
            "恢复前后必须通过当前权益行的稳定标识验证永久解锁，不能误匹配商品列表"
        )
        #expect(
            restoreBody.contains("pending-transactions-count"),
            "恢复完成必须通过稳定标识验证可靠交付积压已经收敛"
        )
        #expect(
            !source.contains("app.staticTexts[\"paymentkit.demo.lifetime\"]"),
            "裸商品 ID 会同时匹配商品列表，不能作为当前权益断言"
        )
        #expect(
            !restoreBody.contains("app.staticTexts[\"待处理交易（0）\"]"),
            "pending 断言必须查询稳定标识，再严格检查动态 label"
        )

        let manageBody = method(
            "testManageSubscriptionsReturnConvergesWithoutManualRefresh",
            in: source
        )
        let compactManageBody = manageBody.filter { !$0.isWhitespace }
        #expect(
            manageBody.contains("app.staticTexts.matching(")
                && manageBody.contains(
                    "identifier: \"auto-renew-status-paymentkit.demo.monthly\""
                ),
            "订阅管理必须按月订阅稳定标识建立可计数的查询"
        )
        #expect(
            manageBody.contains(
                "let monthlyRenewalStatus = monthlyStatuses.firstMatch"
            ),
            "订阅管理必须只在唯一查询上取得 firstMatch"
        )
        #expect(
            compactManageBody.components(
                separatedBy: "XCTAssertEqual(monthlyStatuses.count,1"
            ).count - 1 == 2,
            "系统操作前后都必须断言月订阅状态元素恰好存在一个"
        )
        #expect(
            manageBody.contains(
                "let monthlyRenewalIdentifier = monthlyRenewalStatus.identifier"
            ),
            "进入系统页面前必须记录唯一月订阅状态元素的稳定标识"
        )
        #expect(
            compactManageBody.contains(
                "XCTAssertEqual(monthlyRenewalStatus.identifier,monthlyRenewalIdentifier,"
            ),
            "系统页面返回后必须确认仍查询到同一产品作用域标识"
        )
        #expect(
            !manageBody.contains(
                "app.staticTexts[\"auto-renew-status-paymentkit.demo.monthly\"]"
            )
                && !manageBody.contains(
                    "app.staticTexts[\n            \"auto-renew-status-paymentkit.demo.monthly\"\n        ]"
                ),
            "直接下标查询无法证明匹配唯一，必须使用 matching(identifier:)"
        )
        #expect(
            !manageBody.contains("app.staticTexts[\"将自动续订\"]"),
            "全局文案可能命中另一订阅，不能证明月订阅的操作前状态"
        )
        #expect(
            !manageBody.contains("app.staticTexts[\"不会自动续订\"]"),
            "全局文案可能命中另一订阅，不能证明月订阅的操作后状态"
        )
        let baselineRange = manageBody.range(of: "将自动续订")
        let presentationRange = manageBody.range(of: "manageButton.tap()")
        let convergedRange = manageBody.range(of: "不会自动续订")
        #expect(
            baselineRange?.lowerBound ?? manageBody.endIndex
                < presentationRange?.lowerBound ?? manageBody.startIndex,
            "进入系统订阅管理前必须先证明测试账号处于自动续订状态"
        )
        #expect(
            presentationRange?.lowerBound ?? manageBody.endIndex
                < convergedRange?.lowerBound ?? manageBody.startIndex,
            "关闭自动续订的最终断言必须发生在系统订阅管理返回之后"
        )
    }

    @Test("自动收敛断言使用逐交易和逐订阅稳定标识")
    func automaticConvergenceIdentifiersAreRecordScoped() throws {
        let source = try exampleContentViewSource()

        #expect(
            source.contains(
                ".accessibilityIdentifier(\"entitlement-\\(transaction.productID)\")"
            ),
            "当前权益行必须与商品展示行使用不同的可访问性标识"
        )
        #expect(
            source.contains(
                "\"auto-renew-status-\\(status.renewalInfo.currentProductID)\""
            ),
            "自动续订文案必须按当前订阅商品提供稳定标识"
        )
        #expect(
            source.contains(
                "\"entitlement-billing-plan-\\(transaction.productID)\""
            ),
            "当前权益的账单计划必须按商品提供稳定标识"
        )
        #expect(
            source.contains(".accessibilityIdentifier(\"pending-transactions-count\")"),
            "待处理交易计数必须提供不随数量变化的稳定标识"
        )
    }

    @Test("Sandbox 计划显式执行三条自动收敛 UI 用例")
    func sandboxPlanSelectsAutomaticConvergenceUIFlows() throws {
        let planURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples Sandbox.xctestplan")
        let data = try Data(contentsOf: planURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let testTargets = try #require(root["testTargets"] as? [[String: Any]])
        let uiTarget = try #require(testTargets.first { target in
            let metadata = target["target"] as? [String: Any]
            return metadata?["name"] as? String == "ExamplesUITests"
        })
        let selectedTests = Set(
            try #require(uiTarget["selectedTests"] as? [String])
        )
        let requiredTests: Set<String> = [
            "ExamplesUITests/testPurchaseConvergesWithoutManualRefresh",
            "ExamplesUITests/testRestoreConvergesWithoutManualRefresh",
            "ExamplesUITests/testManageSubscriptionsReturnConvergesWithoutManualRefresh",
        ]

        // 测试仅仅能编译并不代表会被标准 Sandbox 计划执行。
        #expect(requiredTests.isSubset(of: selectedTests))
    }

    @Test("系统界面协调严格按商店会话热重载和后台读取顺序执行")
    @MainActor
    func reconcilesStoreKitPresentationInProductionOrder() async {
        let reloadedSnapshot = PaymentSnapshot(
            canMakePayments: true,
            unavailableProductIDs: ["reloaded"]
        )
        var calls: [String] = []
        let reconciler = StoreKitPresentationReconciler(
            reloadStoreSession: {
                calls.append("reload")
                return reloadedSnapshot
            },
            reloadBackend: {
                calls.append("backend")
            }
        )

        let snapshot = await reconciler.reconcile()

        #expect(calls == ["reload", "backend"])
        #expect(snapshot == reloadedSnapshot)
    }

    @Test("系统界面协调采用热重载返回的保守快照且仍读取后台")
    @MainActor
    func preservesStoreSessionReloadSnapshot() async {
        let preservedSnapshot = PaymentSnapshot(canMakePayments: false)
        var calls: [String] = []
        let reconciler = StoreKitPresentationReconciler(
            reloadStoreSession: {
                calls.append("reload")
                return preservedSnapshot
            },
            reloadBackend: {
                calls.append("backend")
            }
        )

        let snapshot = await reconciler.reconcile()

        #expect(calls == ["reload", "backend"])
        #expect(snapshot == preservedSnapshot)
    }

    @Test("快照事件不访问后台且交易成功和失败各读取一次")
    @MainActor
    func paymentEventReceiverReloadsBackendOnlyForDeliveryChanges() async {
        let updatedSnapshot = PaymentSnapshot(canMakePayments: false)
        let transaction = exampleTransaction()
        var committedSnapshots: [PaymentSnapshot] = []
        var backendReloadCount = 0
        var transactionStatuses: [(UInt64, PaymentFinishState)] = []
        let receiver = ExamplePaymentEventReceiver(
            updateSnapshot: { committedSnapshots.append($0) },
            prependEvent: { _ in },
            updateTransactionStatus: {
                transactionStatuses.append(($0.id, $1))
            },
            reloadBackend: { backendReloadCount += 1 }
        )

        await receiver.receive(.snapshotUpdated(updatedSnapshot))
        #expect(committedSnapshots == [updatedSnapshot])
        #expect(backendReloadCount == 0)
        #expect(transactionStatuses.isEmpty)

        await receiver.receive(
            .transactionDelivered(transaction, finishState: .finished)
        )
        #expect(backendReloadCount == 1)
        #expect(transactionStatuses.count == 1)
        #expect(transactionStatuses[0].0 == transaction.id)
        #expect(transactionStatuses[0].1 == .finished)

        await receiver.receive(
            .transactionProcessingFailed(
                transaction: transaction,
                error: PaymentError(
                    code: .processingFailed,
                    message: "测试处理失败"
                )
            )
        )
        #expect(backendReloadCount == 2)
    }

    @Test("较旧交易晚到时不能覆盖最新交易诊断状态")
    @MainActor
    func olderTransactionCannotReplaceLatestDiagnosticStatus() {
        var status = ExampleTransactionDiagnosticStatus()
        let older = exampleTransaction(
            id: 901,
            signedDate: Date(timeIntervalSince1970: 10)
        )
        let newer = exampleTransaction(
            id: 902,
            signedDate: Date(timeIntervalSince1970: 20)
        )

        #expect(
            status.record(newer, finishState: .finished)
                == "交易已交付并 finish：…902"
        )
        #expect(status.record(older, finishState: .finished) == nil)
        #expect(status.message == "交易已交付并 finish：…902")
    }

    @Test("同一签名事件只能从等待 StoreKit 升级为已 finish")
    @MainActor
    func diagnosticFinishStateOnlyMovesForward() {
        var status = ExampleTransactionDiagnosticStatus()
        let transaction = exampleTransaction(
            id: 903,
            signedDate: Date(timeIntervalSince1970: 30)
        )

        #expect(
            status.record(transaction, finishState: .awaitingStoreKit)
                == "交易已交付，等待 StoreKit finish：…903"
        )
        #expect(
            status.record(transaction, finishState: .finished)
                == "交易已交付并 finish：…903"
        )
        #expect(status.record(transaction, finishState: .awaitingStoreKit) == nil)
        #expect(status.message == "交易已交付并 finish：…903")
    }

    @Test("系统界面展示和返回协调只允许一个在途操作")
    @MainActor
    func storeKitPresentationIsSingleFlight() async {
        let singleFlight = StoreKitPresentationSingleFlight()
        let started = ExampleAsyncLatch()
        let release = ExampleAsyncLatch()
        var operationCount = 0

        let first = Task { @MainActor in
            await singleFlight.perform {
                operationCount += 1
                await started.open()
                await release.wait()
            }
        }
        await started.wait()

        let acceptedDuplicate = await singleFlight.perform {
            operationCount += 1
        }

        #expect(!acceptedDuplicate)
        #expect(operationCount == 1)

        await release.open()
        #expect(await first.value)

        let acceptedAfterCompletion = await singleFlight.perform {
            operationCount += 1
        }
        #expect(acceptedAfterCompletion)
        #expect(operationCount == 2)
    }

    @Test(
        "Sandbox 优惠代码目录展示只使用状态和计数",
        arguments: [
            (
                SandboxOfferCodeCatalogStatus.loaded,
                2, 0, 0,
                "Sandbox 优惠代码：2 条，仅用于测试",
                nil
            ),
            (
                SandboxOfferCodeCatalogStatus.loaded,
                0, 0, 0,
                "未配置 Sandbox 优惠代码",
                nil
            ),
            (
                SandboxOfferCodeCatalogStatus.loaded,
                1, 3, 2,
                "Sandbox 优惠代码：1 条，仅用于测试",
                "无效行：3 条 · 重复行：2 条"
            ),
            (
                SandboxOfferCodeCatalogStatus.missing,
                0, 0, 0,
                "未配置 Sandbox 优惠代码",
                nil
            ),
            (
                SandboxOfferCodeCatalogStatus.empty,
                0, 4, 0,
                "未配置 Sandbox 优惠代码",
                "无效行：4 条"
            ),
            (
                SandboxOfferCodeCatalogStatus.unreadable,
                0, 0, 0,
                "Sandbox 优惠代码配置不可用",
                nil
            ),
            (
                SandboxOfferCodeCatalogStatus.invalidEncoding,
                0, 0, 0,
                "Sandbox 优惠代码配置不可用",
                nil
            ),
            (
                SandboxOfferCodeCatalogStatus.fileTooLarge,
                0, 0, 0,
                "Sandbox 优惠代码配置不可用",
                nil
            ),
            (
                SandboxOfferCodeCatalogStatus.tooManyRecords,
                0, 0, 0,
                "Sandbox 优惠代码配置不可用",
                nil
            ),
        ]
    )
    func sandboxOfferCodeCatalogPresentationIsSanitized(
        status: SandboxOfferCodeCatalogStatus,
        validCodeCount: Int,
        invalidLineCount: Int,
        duplicateLineCount: Int,
        expectedStatusText: String,
        expectedIssueText: String?
    ) {
        let presentation = SandboxOfferCodeCatalogPresentation(
            status: status,
            validCodeCount: validCodeCount,
            invalidLineCount: invalidLineCount,
            duplicateLineCount: duplicateLineCount
        )

        #expect(presentation.statusText == expectedStatusText)
        #expect(presentation.issueText == expectedIssueText)
    }

    @Test("Sandbox 优惠代码仅追加到年订阅现有优惠之后")
    @MainActor
    func appendsSandboxOfferCodesOnlyToYearlySubscription() throws {
        let catalog = try sandboxOfferCodeCatalog()
        let presenter = RecordingSandboxOfferCodePresenter(
            trace: SandboxOfferCodeTestTrace()
        )
        let clipboard = RecordingSandboxOfferCodeModelClipboard(
            trace: SandboxOfferCodeTestTrace()
        )
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard
        )
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        let monthly = sandboxSubscriptionProduct(id: "paymentkit.demo.monthly")

        let yearlyOffers = context.model.availableOffers(for: yearly)
        let monthlyOffers = context.model.availableOffers(for: monthly)
        let sanitizedCodes = catalog.codes.map {
            SandboxOfferCodeDisplayItem(
                id: $0.id,
                displayName: $0.displayName
            )
        }

        #expect(yearlyOffers == [
            .introductory,
            .promotional("existing-promotion"),
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            .sandboxOfferCode(
                id: catalog.codes[1].id,
                displayName: catalog.codes[1].displayName
            ),
        ])
        #expect(monthlyOffers == [
            .introductory,
            .promotional("existing-promotion"),
        ])
        #expect(context.model.sandboxOfferCodes == sanitizedCodes)
        #expect(context.model.sandboxOfferCodeCatalogStatus == catalog.status)
        #expect(
            context.model.sandboxOfferCodeInvalidLineCount
                == catalog.invalidLineCount
        )
        #expect(
            context.model.sandboxOfferCodeDuplicateLineCount
                == catalog.duplicateLineCount
        )
    }

    @Test("本机首购资格有效时不展示无法兑现的标准价格")
    @MainActor
    func eligibleIntroductoryOfferSuppressesMisleadingStandardPrice() throws {
        let catalog = try sandboxOfferCodeCatalog()
        let context = makeSandboxOfferCodeModel(catalog: catalog)
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)

        #expect(!context.model.availableOffers(for: yearly).contains(.standard))
        #expect(context.model.selectedOffer(for: yearly) == .introductory)

        // 即使旧界面状态残留了标准价格，也必须回退到 Apple 实际会应用的首购优惠。
        context.model.selectOffer(.standard, for: yearly.id)

        #expect(context.model.selectedOffer(for: yearly) == .introductory)
        #expect(
            try context.model.purchaseOptions(for: yearly).offer
                == .introductory(eligibility: nil)
        )
    }

    @Test("选择 Sandbox 优惠代码会强制切换年订阅为预付")
    @MainActor
    func selectingSandboxOfferCodeForcesUpFrontBilling() throws {
        let catalog = try sandboxOfferCodeCatalog()
        let context = makeSandboxOfferCodeModel(catalog: catalog)
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        let choice = ExampleOfferChoice.sandboxOfferCode(
            id: catalog.codes[0].id,
            displayName: catalog.codes[0].displayName
        )
        context.model.selectBillingPlan(.monthlyCommitment, for: yearly.id)

        context.model.selectOffer(choice, for: yearly.id)

        #expect(context.model.selectedOffer(for: yearly) == choice)
        #expect(context.model.selectedBillingPlan(for: yearly) == .upFront)
    }

    @Test("月付承诺不会继承预付计划的首购优惠")
    @MainActor
    func monthlyCommitmentDoesNotInheritUpFrontIntroductoryOffer() throws {
        let catalog = try sandboxOfferCodeCatalog()
        let context = makeSandboxOfferCodeModel(catalog: catalog)
        defer { context.cleanup() }
        let introductory = PaymentSubscriptionOffer(
            id: nil,
            type: .introductory,
            price: 148,
            displayPrice: "¥148.00",
            period: .init(unit: .year, value: 1),
            periodCount: 1,
            paymentMode: .payUpFront
        )
        let monthlyCommitment = PaymentSubscriptionPricingTerms(
            billingPlan: .monthlyCommitment,
            billingPrice: 18,
            billingDisplayPrice: "¥18.00",
            billingPeriod: .init(unit: .month, value: 1),
            commitment: .init(
                price: 216,
                displayPrice: "¥216.00",
                period: .init(unit: .year, value: 1)
            ),
            offers: []
        )
        let upFront = PaymentSubscriptionPricingTerms(
            billingPlan: .upFront,
            billingPrice: 198,
            billingDisplayPrice: "¥198.00",
            billingPeriod: .init(unit: .year, value: 1),
            commitment: .init(
                price: 198,
                displayPrice: "¥198.00",
                period: .init(unit: .year, value: 1)
            ),
            offers: [introductory]
        )
        let product = PaymentProduct(
            id: "paymentkit.demo.commitment-test",
            type: .autoRenewableSubscription,
            displayName: "承诺计划测试",
            description: "验证优惠按账单计划隔离",
            price: 198,
            displayPrice: "¥198.00",
            isFamilyShareable: false,
            subscription: PaymentSubscriptionInfo(
                groupID: "test-subscription-group",
                period: .init(unit: .year, value: 1),
                introductoryOffer: introductory,
                pricingTerms: [monthlyCommitment, upFront],
                isEligibleForIntroductoryOffer: true
            )
        )

        #expect(context.model.selectedBillingPlan(for: product) == .monthlyCommitment)
        #expect(context.model.availableOffers(for: product) == [.standard])
        #expect(context.model.selectedOffer(for: product) == .standard)
        let options = try context.model.purchaseOptions(for: product)
        #expect(options.billingPlan == .monthlyCommitment)
        #expect(options.offer == nil)
    }

    @Test("商品行全部价格周期和优惠文案来自当前账单计划")
    func productRowUsesSelectedPricingTermsForEveryDisclosure() throws {
        let source = try exampleContentViewSource()

        #expect(
            source.contains(
                "selectedPricingTerms.billingDisplayPrice"
            ),
            "标准续订价格必须来自当前 pricingTerms"
        )
        #expect(
            source.contains(
                "selectedPricingTerms.billingPeriod.displayName"
            ),
            "购买按钮旁的周期必须来自当前 pricingTerms"
        )
        #expect(
            !source.contains(
                "Text(\"标准续订：\\(product.displayPrice) / \\(subscription.period.displayName)\")"
            ),
            "不能把商品默认年付价格展示为月付承诺的标准续订价格"
        )
        #expect(
            !source.contains(
                "ForEach(subscription.promotionalOffers"
            ),
            "促销说明必须按当前账单计划隔离"
        )
        #expect(
            !source.contains(
                "ForEach(subscription.winBackOffers"
            ),
            "回归优惠说明必须按当前账单计划隔离"
        )
    }

    @Test("Sandbox 优惠代码不能生成普通 Product purchase 参数")
    @MainActor
    func purchaseOptionsRejectSandboxOfferCode() throws {
        let catalog = try sandboxOfferCodeCatalog()
        let context = makeSandboxOfferCodeModel(catalog: catalog)
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        context.model.selectOffer(
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            for: yearly.id
        )

        #expect(throws: ExampleInputError.offerCodeRequiresSystemRedemption) {
            try context.model.purchaseOptions(for: yearly)
        }
    }

    @Test("Sandbox 优惠代码主操作只展示系统兑换并在关闭后协调状态")
    @MainActor
    func sandboxOfferCodeUsesRedemptionRoute() async throws {
        let catalog = try sandboxOfferCodeCatalog()
        let trace = SandboxOfferCodeTestTrace()
        let presenter = RecordingSandboxOfferCodePresenter(trace: trace)
        let clipboard = RecordingSandboxOfferCodeModelClipboard(trace: trace)
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard,
            sandboxOfferCodeReconciliation: {
                trace.entries.append("reconcile")
            }
        )
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        context.model.selectOffer(
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            for: yearly.id
        )

        await context.model.performPrimaryAction(for: yearly)

        let selectedSecret = try #require(
            catalog.secretValue(for: catalog.codes[0].id)
        )
        let wroteSelectedSecret = clipboard.matchesLastStoredValue(
            selectedSecret
        )
        #expect(trace.entries == [
            "prepare",
            "store",
            "present",
            "clear",
            "reconcile",
        ])
        #expect(presenter.presentationCount == 1)
        #expect(clipboard.storeCount == 1)
        #expect(clipboard.clearCount == 1)
        #expect(wroteSelectedSecret)
        #expect(context.model.statusMessage == "Sandbox 优惠代码兑换页已关闭")
        #expect(context.model.errorMessage == nil)
        #expect(!context.model.isBusy)
    }

    @Test("等待关闭的 Sandbox 展示失败仍按清理后协调的顺序收敛")
    @MainActor
    func sandboxOfferCodePresentationFailureStillReconciles() async throws {
        let catalog = try sandboxOfferCodeCatalog()
        let trace = SandboxOfferCodeTestTrace()
        let presenter = RecordingSandboxOfferCodePresenter(
            trace: trace,
            outcome: .failure
        )
        let clipboard = RecordingSandboxOfferCodeModelClipboard(trace: trace)
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard,
            sandboxOfferCodeReconciliation: {
                trace.entries.append("reconcile")
            }
        )
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        context.model.selectOffer(
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            for: yearly.id
        )

        await context.model.performPrimaryAction(for: yearly)

        #expect(trace.entries == [
            "prepare",
            "store",
            "present",
            "clear",
            "reconcile",
        ])
        #expect(
            context.model.errorMessage
                == "Sandbox 优惠代码兑换失败，请稍后重试"
        )
        #expect(!context.model.isBusy)
    }

    @Test("等待关闭的 Sandbox 展示取消仍按清理后协调的顺序收敛")
    @MainActor
    func sandboxOfferCodePresentationCancellationStillReconciles()
        async throws {
        let catalog = try sandboxOfferCodeCatalog()
        let trace = SandboxOfferCodeTestTrace()
        let presenter = RecordingSandboxOfferCodePresenter(
            trace: trace,
            outcome: .cancellation
        )
        let clipboard = RecordingSandboxOfferCodeModelClipboard(trace: trace)
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard,
            sandboxOfferCodeReconciliation: {
                trace.entries.append("reconcile")
            }
        )
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        context.model.selectOffer(
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            for: yearly.id
        )

        await context.model.performPrimaryAction(for: yearly)

        #expect(trace.entries == [
            "prepare",
            "store",
            "present",
            "clear",
            "reconcile",
        ])
        #expect(
            context.model.errorMessage
                == "Sandbox 优惠代码兑换失败，请稍后重试"
        )
        #expect(!context.model.isBusy)
    }

    @Test("准备系统展示上下文失败时不写剪贴板也不协调")
    @MainActor
    func sandboxOfferCodePreparationFailureDoesNotReconcile() async throws {
        let catalog = try sandboxOfferCodeCatalog()
        let trace = SandboxOfferCodeTestTrace()
        let presenter = RecordingSandboxOfferCodePresenter(
            trace: trace,
            preparationFails: true
        )
        let clipboard = RecordingSandboxOfferCodeModelClipboard(trace: trace)
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard,
            sandboxOfferCodeReconciliation: {
                trace.entries.append("reconcile")
            }
        )
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        context.model.selectOffer(
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            for: yearly.id
        )

        await context.model.performPrimaryAction(for: yearly)

        #expect(trace.entries == ["prepare"])
        #expect(clipboard.storeCount == 0)
        #expect(
            context.model.errorMessage
                == "当前没有可用于展示 Sandbox 优惠代码兑换页的系统界面"
        )
    }

    @Test("无关闭信号的 Sandbox 展示使用五分钟本机剪贴板并报告已打开")
    @MainActor
    func sandboxOfferCodeLegacyPresentationRetainsExpiringClipboard()
        async throws {
        let catalog = try sandboxOfferCodeCatalog()
        let trace = SandboxOfferCodeTestTrace()
        let presenter = RecordingSandboxOfferCodePresenter(
            trace: trace,
            presentationKind: .opensWithoutDismissalSignal
        )
        let clipboard = RecordingSandboxOfferCodeModelClipboard(trace: trace)
        let now = Date(timeIntervalSince1970: 10_000)
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard,
            sandboxOfferCodeReconciliation: {
                trace.entries.append("reconcile")
            },
            sandboxOfferCodeNow: { now }
        )
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        context.model.selectOffer(
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            for: yearly.id
        )

        await context.model.performPrimaryAction(for: yearly)

        #expect(trace.entries == [
            "prepare",
            "store",
            "present",
            "reconcile",
        ])
        #expect(
            clipboard.lastPolicy
                == .localOnly(
                    expirationDate: now.addingTimeInterval(5 * 60)
                )
        )
        #expect(clipboard.clearCount == 0)
        #expect(context.model.statusMessage == "Sandbox 优惠代码兑换页已打开")
        #expect(context.model.errorMessage == nil)
    }

    @Test("无关闭信号的 single-flight 在展示调用返回后立即释放")
    @MainActor
    func sandboxOfferCodeLegacySingleFlightExcludesReconciliation()
        async throws {
        let catalog = try sandboxOfferCodeCatalog()
        let trace = SandboxOfferCodeTestTrace()
        let presenter = RecordingSandboxOfferCodePresenter(
            trace: trace,
            presentationKind: .opensWithoutDismissalSignal
        )
        let clipboard = RecordingSandboxOfferCodeModelClipboard(trace: trace)
        let reconciliationStarted = ExampleAsyncLatch()
        let releaseFirstReconciliation = ExampleAsyncLatch()
        var reconciliationCount = 0
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard,
            sandboxOfferCodeReconciliation: {
                reconciliationCount += 1
                trace.entries.append("reconcile")
                if reconciliationCount == 1 {
                    await reconciliationStarted.open()
                    await releaseFirstReconciliation.wait()
                }
            }
        )
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        context.model.selectOffer(
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            for: yearly.id
        )

        let first = Task { @MainActor in
            await context.model.performPrimaryAction(for: yearly)
        }
        await reconciliationStarted.wait()

        #expect(!context.model.isBusy)
        await context.model.performPrimaryAction(for: yearly)

        #expect(presenter.presentationCount == 2)
        #expect(clipboard.storeCount == 2)

        await releaseFirstReconciliation.open()
        await first.value
    }

    @Test("错误商品的 Sandbox 优惠代码主操作在读取和展示前安全失败")
    @MainActor
    func sandboxOfferCodeRejectsWrongProduct() async throws {
        let catalog = try sandboxOfferCodeCatalog()
        let trace = SandboxOfferCodeTestTrace()
        let presenter = RecordingSandboxOfferCodePresenter(trace: trace)
        let clipboard = RecordingSandboxOfferCodeModelClipboard(trace: trace)
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard,
            sandboxOfferCodeReconciliation: {
                trace.entries.append("reconcile")
            }
        )
        defer { context.cleanup() }
        let monthly = sandboxSubscriptionProduct(id: "paymentkit.demo.monthly")
        context.model.selectOffer(
            .sandboxOfferCode(
                id: catalog.codes[0].id,
                displayName: catalog.codes[0].displayName
            ),
            for: monthly.id
        )

        await context.model.performPrimaryAction(for: monthly)

        #expect(trace.entries.isEmpty)
        #expect(presenter.presentationCount == 0)
        #expect(clipboard.storeCount == 0)
        #expect(context.model.errorMessage == "Sandbox 优惠代码仅适用于年订阅")
        expectNoSandboxOfferCodeSecret(in: context.model, catalog: catalog)
    }

    @Test("不存在的 Sandbox 优惠代码 id 在展示前安全失败")
    @MainActor
    func sandboxOfferCodeRejectsMissingID() async throws {
        let catalog = try sandboxOfferCodeCatalog()
        let trace = SandboxOfferCodeTestTrace()
        let presenter = RecordingSandboxOfferCodePresenter(trace: trace)
        let clipboard = RecordingSandboxOfferCodeModelClipboard(trace: trace)
        let context = makeSandboxOfferCodeModel(
            catalog: catalog,
            presenter: presenter,
            clipboard: clipboard,
            sandboxOfferCodeReconciliation: {
                trace.entries.append("reconcile")
            }
        )
        defer { context.cleanup() }
        let yearly = sandboxSubscriptionProduct(id: ExampleProducts.yearly)
        context.model.selectOffer(
            .sandboxOfferCode(id: 999, displayName: "不可用的脱敏选项"),
            for: yearly.id
        )

        await context.model.performPrimaryAction(for: yearly)

        #expect(trace.entries.isEmpty)
        #expect(presenter.presentationCount == 0)
        #expect(clipboard.storeCount == 0)
        #expect(context.model.errorMessage == "所选 Sandbox 优惠代码不可用")
        expectNoSandboxOfferCodeSecret(in: context.model, catalog: catalog)
    }

    @Test("iOS 与 macOS 退款入口分别接入系统界面协调")
    func bothRefundPresentationsReconcileState() throws {
        let source = try exampleModelSource()
        let iOSSection = try #require(
            source.range(of: "#if os(iOS)", options: .backwards)
        )
        let macOSSection = try #require(
            source.range(
                of: "#elseif os(macOS)",
                range: iOSSection.upperBound..<source.endIndex
            )
        )
        let iOSSource = String(source[iOSSection.lowerBound..<macOSSection.lowerBound])
        let macOSSource = String(source[macOSSection.lowerBound...])

        #expect(method("requestRefund", in: iOSSource).contains(
            "reconcileAfterStoreKitPresentation"
        ))
        #expect(method("requestRefund", in: macOSSource).contains(
            "reconcileAfterStoreKitPresentation"
        ))
    }

    @Test("配置文件包含 Sandbox 的三种商品类型")
    func loadsEveryProductType() async throws {
        let context = try makeContext()
        defer { context.cleanup() }

        guard let products = try await loadProductsOrRecordEnvironmentIssue(context) else {
            return
        }

        #expect(products.map(\.id) == productIDs)
        #expect(Set(products.map(\.type)) == [
            .consumable,
            .nonConsumable,
            .autoRenewableSubscription,
        ])
    }

    @Test("新会话加载月免费试用和年预付首购优惠")
    func loadsIntroductoryOffersForSubscriptionGroup() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let products = try #require(
            try await loadProductsOrRecordEnvironmentIssue(context)
        )
        let monthly = try #require(products.first { $0.id == productIDs[2] })
        let annual = try #require(products.first { $0.id == productIDs[3] })
        let monthlySubscription = try #require(monthly.subscription)
        let annualSubscription = try #require(annual.subscription)
        let monthlyOffer = try #require(monthlySubscription.introductoryOffer)
        let annualOffer = try #require(annualSubscription.introductoryOffer)

        #expect(monthlySubscription.groupID == annualSubscription.groupID)
        #expect(monthlySubscription.isEligibleForIntroductoryOffer)
        #expect(annualSubscription.isEligibleForIntroductoryOffer)
        #expect(monthlyOffer.paymentMode == .freeTrial)
        #expect(monthlyOffer.period == PaymentSubscriptionPeriod(unit: .week, value: 1))
        #expect(monthlyOffer.periodCount == 1)
        #expect(annualOffer.paymentMode == .payUpFront)
        #expect(annualOffer.period == PaymentSubscriptionPeriod(unit: .year, value: 1))
        #expect(annualOffer.periodCount == 1)
        #expect(annualOffer.price == Decimal(string: "148"))
    }

    @Test("加载促销和月付承诺定价")
    func loadsEveryConfiguredSubscriptionOfferAndPricingPlan() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let products = try #require(
            try await loadProductsOrRecordEnvironmentIssue(context)
        )
        let monthly = try #require(
            products.first { $0.id == productIDs[2] }?.subscription
        )
        let annual = try #require(
            products.first { $0.id == productIDs[3] }?.subscription
        )

        let promotional = try #require(monthly.promotionalOffers.first)
        #expect(monthly.promotionalOffers.count == 1)
        #expect(promotional.id == "pk_monthly_promo_099_2m_2026")
        #expect(promotional.type == .promotional)
        #expect(promotional.price == Decimal(string: "8"))
        #expect(promotional.paymentMode == .payAsYouGo)
        #expect(promotional.period == .init(unit: .month, value: 1))
        #expect(promotional.periodCount == 2)

        #expect(monthly.winBackOffers.isEmpty)

        if #available(iOS 26.4, macOS 26.4, *) {
            #expect(annual.pricingTerms.count == 2)
            let commitment = try #require(
                annual.pricingTerms.first {
                    $0.billingPlan == .monthlyCommitment
                }
            )
            #expect(commitment.billingPrice == Decimal(string: "18"))
            #expect(commitment.billingPeriod == .init(unit: .month, value: 1))
            #expect(commitment.commitment.price == Decimal(string: "216"))
            #expect(commitment.commitment.period == .init(unit: .year, value: 1))
        }
    }

    @Test("月订阅交易记录免费试用且购买后同组资格失效")
    func monthlyPurchaseAppliesFreeTrial() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else { return }

            guard case .completed(let transaction) = try await context.client.purchase(
                productID: productIDs[2]
            ) else {
                Issue.record("月订阅首购没有产生完成交易")
                return
            }
            #expect(transaction.appliedOffer?.type == .introductory)
            #expect(transaction.appliedOffer?.paymentMode == .freeTrial)
            #expect(
                transaction.appliedOffer?.period
                    == PaymentSubscriptionPeriod(unit: .week, value: 1)
            )
            try await waitUntil(description: "同订阅组首购资格未失效") {
                guard let products = try? await context.client.reloadProducts() else {
                    return false
                }
                let groupProducts = products.filter {
                    $0.subscription?.groupID == transaction.subscriptionGroupID
                }
                return groupProducts.count == 2 && groupProducts.allSatisfy {
                    $0.subscription?.isEligibleForIntroductoryOffer == false
                }
            }
        }
    }

    @Test("年订阅交易记录首年预付且后续续订恢复标准价格")
    func annualPurchaseAppliesPayUpFrontOnlyOnce() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else { return }

            guard case .completed(let introductoryTransaction) = try await context.client.purchase(
                productID: productIDs[3]
            ) else {
                Issue.record("年订阅首购没有产生完成交易")
                return
            }
            #expect(introductoryTransaction.appliedOffer?.type == .introductory)
            #expect(introductoryTransaction.appliedOffer?.paymentMode == .payUpFront)
            #expect(
                introductoryTransaction.appliedOffer?.period
                    == PaymentSubscriptionPeriod(unit: .year, value: 1)
            )

            try context.session.forceRenewalOfSubscription(productIdentifier: productIDs[3])
            try await waitUntil(description: "年订阅标准续订交易未送达") {
                await context.processor.transactions(for: self.productIDs[3]).contains {
                    $0.id != introductoryTransaction.id && $0.appliedOffer == nil
                }
            }
            let renewals = await context.processor.transactions(for: productIDs[3])
            #expect(renewals.contains {
                $0.id == introductoryTransaction.id
                    && $0.appliedOffer?.type == .introductory
            })
            #expect(renewals.contains {
                $0.id != introductoryTransaction.id && $0.appliedOffer == nil
            })
        }
    }

    @Test("促销优惠交易通过监听映射实际优惠")
    @available(iOS 17.0, macOS 14.0, *)
    func promotionalOfferTransactionIsDeliveredWithAppliedOffer() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }

            // 促销优惠面向现有或曾订阅用户；先创建并结束一段真实订阅历史，
            // 避免以无资格的新账户调用 StoreKitTest 形成无意义的系统错误。
            _ = try await context.session.buyProduct(identifier: productIDs[2])
            try context.session.expireSubscription(productIdentifier: productIDs[2])
            try await waitUntil(description: "促销优惠前置订阅未进入已过期状态") {
                guard let snapshot = try? await context.client.refresh() else { return false }
                return snapshot.subscriptionStatuses.contains { $0.state == .expired }
            }

            _ = try await context.session.buyProduct(
                identifier: productIDs[2],
                options: [
                    .promotionalOffer(id: "pk_monthly_promo_099_2m_2026"),
                ]
            )
            try await waitUntil(description: "促销优惠交易未送达处理器") {
                await context.processor.transactions(for: self.productIDs[2]).contains {
                    $0.appliedOffer?.type == .promotional
                }
            }
            let transaction = try #require(
                await context.processor.transactions(for: productIDs[2]).first {
                    $0.appliedOffer?.type == .promotional
                }
            )
            #expect(transaction.appliedOffer?.id == "pk_monthly_promo_099_2m_2026")
            #expect(transaction.appliedOffer?.paymentMode == .payAsYouGo)
            // 交易只携带每个优惠扣款周期；“共 2 期”属于商品优惠元数据，
            // 不能把它折算成两个月后写回交易快照。
            #expect(transaction.appliedOffer?.period == .init(unit: .month, value: 1))
        }
    }

    @Test("优惠代码交易通过监听映射实际优惠")
    @available(iOS 17.0, macOS 14.0, *)
    func offerCodeTransactionIsDeliveredWithAppliedOffer() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }

            _ = try await context.session.buyProduct(
                identifier: productIDs[3],
                options: [
                    .codeOffer(referenceName: "pk_annual_code_999_2026"),
                ]
            )
            try await waitUntil(description: "优惠代码交易未送达处理器") {
                await context.processor.transactions(for: self.productIDs[3]).contains {
                    $0.appliedOffer?.type == .offerCode
                }
            }
            let transaction = try #require(
                await context.processor.transactions(for: productIDs[3]).first {
                    $0.appliedOffer?.type == .offerCode
                }
            )
            #expect(transaction.appliedOffer?.id == "pk_annual_code_999_2026")
            #expect(transaction.appliedOffer?.paymentMode == .payUpFront)
            #expect(transaction.appliedOffer?.period == .init(unit: .year, value: 1))
        }
    }

    @Test("月付承诺交易保留账单计划和承诺进度")
    @available(iOS 26.4, macOS 26.4, *)
    func monthlyCommitmentTransactionPreservesBillingPlan() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }

            let storeTransaction = try await context.session.buyProduct(
                identifier: productIDs[3],
                options: [.billingPlanType(.monthly)]
            )
            #expect(storeTransaction.billingPlanType == .monthly)
            #expect(storeTransaction.commitmentInfo?.totalBillingPeriods == 12)
            #expect(storeTransaction.commitmentInfo?.billingPeriodNumber == 1)
            try await waitUntil(description: "月付承诺交易未送达处理器") {
                await context.processor.transactions(for: self.productIDs[3]).contains {
                    $0.billingPlan == .monthlyCommitment
                }
            }
            let transaction = try #require(
                await context.processor.transactions(for: productIDs[3]).first {
                    $0.billingPlan == .monthlyCommitment
                }
            )
            #expect(transaction.commitment?.totalBillingPeriods == 12)
            #expect(transaction.commitment?.billingPeriodNumber == 1)
        }
    }

    @Test("购买成功后先交给模拟后台再结束交易")
    func purchasesEveryProductType() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }

            // 先买服务等级 2 的月订阅，再升级到等级 1 的年订阅，两个购买都会立即产生新交易。
            // 反向顺序属于降级，StoreKit 会保留当前年订阅并在下个周期才切换产品。
            let purchaseOrder = [
                productIDs[0], productIDs[1], productIDs[2], productIDs[3],
            ]

            for productID in purchaseOrder {
                let outcome = try await context.client.purchase(productID: productID)
                guard case .completed(let transaction) = outcome else {
                    Issue.record("商品 \(productID) 未返回完成状态")
                    continue
                }
                #expect(transaction.productID == productID)
            }

            let deliveredProductIDs = await context.processor.productIDs()
            // 自动续期订阅升级可能为原订阅额外发送 isUpgraded 状态。处理器必须收到
            // 每种商品，但 Transaction.updates 与 purchase 返回之间没有全局顺序保证。
            #expect(Set(deliveredProductIDs) == Set(purchaseOrder))
            for productID in purchaseOrder {
                #expect(deliveredProductIDs.contains(productID))
            }
            #expect(context.session.allTransactions().allSatisfy { $0.state == .purchased })
        }
    }

    @Test("Ask to Buy 批准后通过交易监听完成处理")
    func approvesAskToBuyPurchase() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.session.askToBuyEnabled = true
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }

            let outcome = try await context.client.purchase(
                productID: productIDs[0],
                options: PurchaseOptions(simulatesAskToBuyInSandbox: true)
            )
            #expect(outcome == .pending)

            let pending = try #require(
                context.session.allTransactions().first { $0.pendingAskToBuyConfirmation }
            )
            try context.session.approveAskToBuyTransaction(identifier: pending.identifier)

            // StoreKit 通过 Transaction.updates 异步发送批准后的交易，测试等待处理器确认。
            try await waitUntil {
                await context.processor.productIDs().contains(self.productIDs[0])
            }
        }
    }

    @Test("Ask to Buy 拒绝后不会交付交易")
    func declinesAskToBuyPurchase() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.session.askToBuyEnabled = true
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else { return }

            let outcome = try await context.client.purchase(
                productID: productIDs[0],
                options: PurchaseOptions(simulatesAskToBuyInSandbox: true)
            )
            #expect(outcome == .pending)
            let pending = try #require(
                context.session.allTransactions().first { $0.pendingAskToBuyConfirmation }
            )
            try context.session.declineAskToBuyTransaction(identifier: pending.identifier)
            try await Task.sleep(nanoseconds: 200_000_000)

            #expect(await context.processor.productIDs().isEmpty)
        }
    }

    @Test("中断购买解决后通过交易监听继续交付")
    func resolvesInterruptedPurchase() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.session.interruptedPurchasesEnabled = true
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else { return }

            let outcome = try await context.client.purchase(productID: productIDs[1])
            #expect(outcome == .pending)
            let interrupted = try #require(
                context.session.allTransactions().first { $0.hasPurchaseIssue }
            )
            context.session.interruptedPurchasesEnabled = false
            try context.session.resolveIssueForTransaction(identifier: interrupted.identifier)

            try await waitUntil {
                await context.processor.productIDs().contains(self.productIDs[1])
            }
        }
    }

    @Test("消耗型数量和 appAccountToken 进入签名交易")
    func preservesQuantityAndAppAccountToken() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else { return }
            let token = UUID()

            guard case .completed(let transaction) = try await context.client.purchase(
                productID: productIDs[0],
                options: PurchaseOptions(quantity: 3, appAccountToken: token)
            ) else {
                Issue.record("数量购买没有产生完成交易")
                return
            }

            #expect(transaction.purchasedQuantity == 3)
            #expect(transaction.appAccountToken == token)
        }
    }

    @Test("空账户恢复不会伪造交付或权益")
    func restoresEmptyAccount() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else { return }

        let snapshot = try await context.client.restorePurchases()

        #expect(await context.processor.productIDs().isEmpty)
        #expect(snapshot.currentEntitlements.isEmpty)
        #expect(snapshot.pendingTransactions.isEmpty)
    }

    @Test("同组月订阅和年订阅可执行等级切换")
    func changesSubscriptionLevel() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else { return }

            _ = try await context.client.purchase(productID: productIDs[2])
            _ = try await context.client.purchase(productID: productIDs[3])
            let snapshot = try await context.client.refresh()

            let deliveredProductIDs = await context.processor.productIDs()
            // 等级切换会为原交易生成 isUpgraded 等新签名状态，监听与购买返回的到达顺序
            // 也不构成 API 契约；此用例只验证两个商品都已交付且没有串入无关商品。
            #expect(Set(deliveredProductIDs) == Set([productIDs[3], productIDs[2]]))
            #expect(deliveredProductIDs.contains(productIDs[3]))
            #expect(deliveredProductIDs.contains(productIDs[2]))
            #expect(!snapshot.subscriptionStatuses.isEmpty)
            #expect(Set(context.session.allTransactions().map(\.productIdentifier)).isSuperset(of: [
                productIDs[2], productIDs[3]
            ]))
        }
    }

    @Test("关闭自动续订和价格上涨状态可被刷新")
    @available(iOS 15.4, macOS 13.0, *)
    func observesAutoRenewAndPriceIncreaseChanges() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else { return }

            _ = try await context.client.purchase(productID: productIDs[2])
            let testTransaction = try #require(
                context.session.allTransactions().first { $0.productIdentifier == productIDs[2] }
            )
            try context.session.disableAutoRenewForTransaction(identifier: testTransaction.identifier)
            try await waitUntil(description: "关闭自动续订状态未传播") {
                guard let snapshot = try? await context.client.refresh() else { return false }
                return snapshot.subscriptionStatuses.contains { !$0.renewalInfo.willAutoRenew }
            }

            try context.session.enableAutoRenewForTransaction(identifier: testTransaction.identifier)
            try context.session.requestPriceIncreaseConsentForTransaction(identifier: testTransaction.identifier)
            try await waitUntil(description: "价格上涨待同意状态未传播") {
                guard let snapshot = try? await context.client.refresh() else { return false }
                return snapshot.subscriptionStatuses.contains {
                    $0.renewalInfo.priceIncreaseStatus == .pending
                }
            }
        }
    }

    /// 使用系统 StoreKitTest 错误注入验证真实网关的错误边界。
    ///
    /// `SKTestSession.setSimulatedError` 从 iOS 17、macOS 14 开始提供；
    /// 更早系统的相同公共错误映射由可控网关单元测试覆盖。
    @Test("StoreKit 强制商品错误映射为稳定公共错误")
    @available(iOS 17.0, macOS 14.0, *)
    func mapsSimulatedLoadProductsError() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let simulated = SKTestFailures.LoadProducts.generic(
            .networkError(URLError(.notConnectedToInternet))
        )
        try await context.session.setSimulatedError(simulated, forAPI: .loadProducts)

        do {
            _ = try await context.client.reloadProducts()
            Issue.record("StoreKit 强制错误不应返回成功")
        } catch let error as PaymentError {
            #expect(error.code == .storeKitFailed)
            #expect(error.message == "加载商品失败：App Store 网络错误（-1009）")
        }
        try await context.session.setSimulatedError(nil, forAPI: .loadProducts)
    }

    @Test("退款撤销会作为新的签名状态再次送达")
    func processesRefundRevocation() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }

            guard case .completed(let transaction) = try await context.client.purchase(
                productID: productIDs[1]
            ) else {
                Issue.record("非消耗型商品购买未完成")
                return
            }
            try context.session.refundTransaction(identifier: UInt(transaction.id))

            // 撤销沿用 transaction ID，但 JWS 与 signedDate 已变化，因此必须再次处理。
            try await waitUntil {
                await context.processor.processCount(for: self.productIDs[1]) == 2
            }
        }
    }

    @Test("自动续订和到期会刷新订阅状态")
    func renewsAndExpiresSubscription() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }

            guard case .completed(let initialTransaction) = try await context.client.purchase(
                productID: productIDs[2]
            ) else {
                Issue.record("月订阅购买没有产生完成交易")
                return
            }
            try context.session.forceRenewalOfSubscription(productIdentifier: productIDs[2])
            try await waitUntil(description: "强制续订交易未送达处理器") {
                await context.processor.transactions(for: self.productIDs[2]).contains {
                    $0.id != initialTransaction.id
                }
            }

            try context.session.expireSubscription(productIdentifier: productIDs[2])
            try await waitUntil(description: "订阅到期状态未传播") {
                guard let snapshot = try? await context.client.refresh() else { return false }
                return snapshot.subscriptionStatuses.contains { $0.state == .expired }
            }
        }
    }

    @Test("账单重试和宽限期可从订阅状态观察")
    @available(iOS 15.4, *)
    func observesBillingRetryAndGracePeriod() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }

            _ = try await context.client.purchase(productID: productIDs[2])
            context.session.shouldEnterBillingRetryOnRenewal = true
            context.session.billingGracePeriodIsEnabled = true
            try context.session.forceRenewalOfSubscription(productIdentifier: productIDs[2])

            try await waitUntil {
                guard let snapshot = try? await context.client.refresh() else { return false }
                return snapshot.subscriptionStatuses.contains {
                    $0.state == .inBillingRetryPeriod || $0.state == .inGracePeriod
                }
            }
        }
    }

    @Test("处理失败的 unfinished 交易可以重放")
    func replaysUnfinishedTransaction() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let processor = FailingOnceProcessor()
        let storageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }
        let pendingDatabaseURL = storageDirectoryURL
            .appendingPathComponent("pending-transactions.sqlite3", isDirectory: false)
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: productIDs),
            processor: processor,
            logger: DisabledPaymentLogHandler(),
            pendingTransactionsDatabaseURL: pendingDatabaseURL
        )
        let context = TestContext(
            session: session,
            client: client,
            processor: RecordingProcessor(),
            storageDirectoryURL: storageDirectoryURL
        )
        guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
            return
        }

        do {
            _ = try await client.purchase(productID: productIDs[1])
            Issue.record("首次后台失败时购买不应返回完成")
        } catch let error as PaymentError {
            #expect(error.code == .processingFailed)
        }

        // 在真实 iOS 文件系统上验证 outbox 的权限、备份排除和 Data Protection 属性。
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: pendingDatabaseURL.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: storageDirectoryURL.path
        )
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try pendingDatabaseURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true)
        #if os(iOS) && !targetEnvironment(simulator)
        // 模拟器使用 macOS 宿主文件系统，不会回报 iOS Data Protection 等级；该属性只在真机验收。
        #expect(
            fileAttributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )
        #expect(
            directoryAttributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )
        #endif

        await client.retryUnfinishedTransactions()
        #expect(await processor.processCount == 2)
    }

    @Test("模拟后台恢复正常后自动重放 outbox")
    @MainActor
    func backendRecoveryAutomaticallyReplaysOutbox() async throws {
        let session = try makeSession()
        let storageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let backend = MockTransactionProcessor(
            latencyMilliseconds: 0,
            databaseURL: storageDirectoryURL
                .appendingPathComponent("mock-backend.sqlite3", isDirectory: false)
        )
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: productIDs),
            processor: backend,
            logger: DisabledPaymentLogHandler(),
            pendingTransactionsDatabaseURL: storageDirectoryURL
                .appendingPathComponent("pending-transactions.sqlite3", isDirectory: false)
        )
        let context = TestContext(
            session: session,
            client: client,
            processor: RecordingProcessor(),
            storageDirectoryURL: storageDirectoryURL
        )
        defer { context.cleanup() }
        let model = PaymentKitExampleModel(
            client: client,
            backend: backend,
            startsAutomatically: false
        )

        try await context.withStartedClient {
            guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
                return
            }
            await backend.setFaultMode(.offline)

            do {
                _ = try await client.purchase(productID: productIDs[0])
                Issue.record("离线模拟后台不应报告购买可靠交付完成")
            } catch let error as PaymentError {
                #expect(error.code == .processingFailed)
            }

            // 只改变模拟后台状态；不得依赖诊断刷新或人工“重试 unfinished”按钮。
            model.setBackendFaultMode(.normal)
            try await waitUntil(description: "后台恢复正常后 outbox 未自动重放") {
                let backendSnapshot = await backend.snapshot()
                let paymentSnapshot = await client.snapshot()
                return backendSnapshot.businessDeliveryCount == 1
                    && paymentSnapshot.pendingTransactions.isEmpty
            }

            #expect(await backend.snapshot().businessDeliveryCount == 1)
            #expect(await client.snapshot().pendingTransactions.isEmpty)
        }
    }

    @Test("外部购买可以通过显式恢复处理")
    func restoresExternalPurchase() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        guard try await loadProductsOrRecordEnvironmentIssue(context) != nil else {
            return
        }

        if #available(iOS 17.0, macOS 14.0, *) {
            _ = try await context.session.buyProduct(identifier: productIDs[1])
            _ = try await context.client.restorePurchases()
            #expect(await context.processor.productIDs().contains(productIDs[1]))
        }
    }

    private func makeContext() throws -> TestContext {
        let session = try makeSession()
        let storageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let processor = RecordingProcessor()
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: productIDs),
            processor: processor,
            logger: DisabledPaymentLogHandler(),
            pendingTransactionsDatabaseURL: storageDirectoryURL
                .appendingPathComponent("pending-transactions.sqlite3", isDirectory: false)
        )
        return TestContext(
            session: session,
            client: client,
            processor: processor,
            storageDirectoryURL: storageDirectoryURL
        )
    }

    private func exampleModelSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/PaymentKitExampleModel.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func exampleContentViewSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/ContentView.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func examplesUITestSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExamplesUITests/ExamplesUITests.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func retryReport(snapshot: PaymentSnapshot) -> PaymentRetryReport {
        PaymentRetryReport(
            attemptedCount: 0,
            deliveredCount: 0,
            finishedCount: 0,
            awaitingFinishCount: 0,
            failureCount: 0,
            unresolvedCount: 0,
            snapshot: snapshot
        )
    }

    private func exampleTransaction(
        id: UInt64 = 901,
        signedDate: Date = Date(timeIntervalSince1970: 2)
    ) -> PaymentTransaction {
        PaymentTransaction(
            id: id,
            originalID: id,
            productID: "paymentkit.demo.lifetime",
            subscriptionGroupID: nil,
            productType: .nonConsumable,
            purchaseDate: Date(timeIntervalSince1970: 1),
            originalPurchaseDate: Date(timeIntervalSince1970: 1),
            expirationDate: nil,
            revocationDate: nil,
            signedDate: signedDate,
            ownershipType: .purchased,
            purchasedQuantity: 1,
            appAccountToken: nil,
            isUpgraded: false,
            jwsRepresentation: "test-header.test-payload.test-signature"
        )
    }

    @MainActor
    private func makeSandboxOfferCodeModel(
        catalog: SandboxOfferCodeCatalog,
        presenter: (any SandboxOfferCodeRedeemSheetPresenting)? = nil,
        clipboard: (any SandboxOfferCodeClipboard)? = nil,
        sandboxOfferCodeReconciliation: (@MainActor () async -> Void)? = nil,
        sandboxOfferCodeNow: @escaping @MainActor () -> Date = Date.init
    ) -> SandboxOfferCodeModelTestContext {
        let storageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let backend = MockTransactionProcessor(
            latencyMilliseconds: 0,
            databaseURL: storageDirectoryURL
                .appendingPathComponent("mock-backend.sqlite3", isDirectory: false)
        )
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: []),
            processor: backend,
            logger: DisabledPaymentLogHandler(),
            pendingTransactionsDatabaseURL: storageDirectoryURL
                .appendingPathComponent("pending-transactions.sqlite3", isDirectory: false)
        )
        let model = PaymentKitExampleModel(
            client: client,
            backend: backend,
            startsAutomatically: false,
            sandboxOfferCodeCatalog: catalog,
            sandboxOfferCodeClipboard: clipboard,
            sandboxOfferCodePresenter: presenter,
            sandboxOfferCodeReconciliation: sandboxOfferCodeReconciliation,
            sandboxOfferCodeNow: sandboxOfferCodeNow
        )
        return SandboxOfferCodeModelTestContext(
            model: model,
            storageDirectoryURL: storageDirectoryURL
        )
    }

    private func sandboxOfferCodeCatalog() throws -> SandboxOfferCodeCatalog {
        try SandboxOfferCodeCatalog.parse(
            Data("TESTCODE0000000001\nTESTCODE0000000002".utf8)
        )
    }

    private func sandboxSubscriptionProduct(id: String) -> PaymentProduct {
        let introductory = PaymentSubscriptionOffer(
            id: nil,
            type: .introductory,
            price: 0,
            displayPrice: "免费",
            period: .init(unit: .week, value: 1),
            periodCount: 1,
            paymentMode: .freeTrial
        )
        let promotional = PaymentSubscriptionOffer(
            id: "existing-promotion",
            type: .promotional,
            price: 1,
            displayPrice: "¥1",
            period: .init(unit: .month, value: 1),
            periodCount: 1,
            paymentMode: .payAsYouGo
        )
        let upFront = PaymentSubscriptionPricingTerms(
            billingPlan: .upFront,
            billingPrice: 10,
            billingDisplayPrice: "¥10",
            billingPeriod: .init(unit: .year, value: 1),
            commitment: .init(
                price: 10,
                displayPrice: "¥10",
                period: .init(unit: .year, value: 1)
            ),
            offers: [introductory, promotional]
        )
        return PaymentProduct(
            id: id,
            type: .autoRenewableSubscription,
            displayName: "测试订阅",
            description: "测试使用的订阅商品",
            price: 10,
            displayPrice: "¥10",
            isFamilyShareable: false,
            subscription: PaymentSubscriptionInfo(
                groupID: "test-subscription-group",
                period: .init(unit: .year, value: 1),
                introductoryOffer: introductory,
                promotionalOffers: [promotional],
                pricingTerms: [upFront],
                isEligibleForIntroductoryOffer: true
            )
        )
    }

    @MainActor
    private func expectNoSandboxOfferCodeSecret(
        in model: PaymentKitExampleModel,
        catalog: SandboxOfferCodeCatalog
    ) {
        let messages = [model.statusMessage, model.errorMessage ?? ""] + model.events
        for code in catalog.codes {
            let secret = catalog.secretValue(for: code.id) ?? ""
            #expect(!messages.contains { $0.contains(secret) })
            #expect(!messages.contains { $0.contains(String(secret.suffix(4))) })
        }
    }

    private func method(_ name: String, in source: String) -> String {
        guard
            let declaration = source.range(of: "func \(name)"),
            let openingBrace = source[declaration.lowerBound...].firstIndex(of: "{")
        else {
            return ""
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let end = source.index(after: index)
                    return String(source[declaration.lowerBound..<end])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return ""
    }

    private func makeSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "PaymentKit")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    private func loadProductsOrRecordEnvironmentIssue(
        _ context: TestContext
    ) async throws -> [PaymentProduct]? {
        let products = try await context.client.reloadProducts()
        guard !products.isEmpty else {
            // 空商品意味着 StoreKitTest 没有真正执行；必须明确失败，不能由 fake 单测形成假绿。
            Issue.record("StoreKitTest 环境未加载任何商品；本次集成测试无效")
            return nil
        }

        guard products.map(\.id) == productIDs else {
            Issue.record("StoreKit 返回的商品集合或顺序与配置不一致")
            return nil
        }
        return products
    }

    private func waitUntil(
        timeout: TimeInterval = 15,
        description: String = "异步条件未满足",
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        // 整套 StoreKitTest 连续运行时，storekitd 的状态传播偶尔会超过 5 秒。
        // 这里保留有限等待和最终断言，只扩大系统调度预算，不把未发生的状态记作通过。
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("等待 StoreKit 异步状态超时：\(description)")
    }
}

private actor ExampleAsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum ExampleReconciliationTestError: Error {
    case refreshFailed
}

@MainActor
private final class SandboxOfferCodeTestTrace {
    var entries: [String] = []
}

@MainActor
private final class RecordingSandboxOfferCodePresenter:
    SandboxOfferCodeRedeemSheetPresenting {
    private let trace: SandboxOfferCodeTestTrace
    private let presentationKind: SandboxOfferCodeTestPresentationKind
    private let outcome: SandboxOfferCodeTestPresentationOutcome
    private let preparationFails: Bool
    private(set) var presentationCount = 0

    init(
        trace: SandboxOfferCodeTestTrace,
        presentationKind: SandboxOfferCodeTestPresentationKind =
            .waitsForDismissal,
        outcome: SandboxOfferCodeTestPresentationOutcome = .success,
        preparationFails: Bool = false
    ) {
        self.trace = trace
        self.presentationKind = presentationKind
        self.outcome = outcome
        self.preparationFails = preparationFails
    }

    func preparedPresentation() throws -> SandboxOfferCodePreparedPresentation {
        trace.entries.append("prepare")
        if preparationFails {
            throw SandboxOfferCodeTestPresentationError()
        }
        let presentation: SandboxOfferCodeSystemPresentation = { [self] in
            presentationCount += 1
            trace.entries.append("present")
            switch outcome {
            case .success:
                return
            case .failure:
                throw SandboxOfferCodeTestPresentationError()
            case .cancellation:
                throw CancellationError()
            }
        }
        switch presentationKind {
        case .waitsForDismissal:
            return .waitsForDismissal(presentation)
        case .opensWithoutDismissalSignal:
            return .opensWithoutDismissalSignal(presentation)
        }
    }
}

private enum SandboxOfferCodeTestPresentationKind {
    case waitsForDismissal
    case opensWithoutDismissalSignal
}

private enum SandboxOfferCodeTestPresentationOutcome {
    case success
    case failure
    case cancellation
}

private struct SandboxOfferCodeTestPresentationError: Error {}

@MainActor
private final class RecordingSandboxOfferCodeModelClipboard:
    SandboxOfferCodeClipboard {
    private let trace: SandboxOfferCodeTestTrace
    private var changeCount = 0
    private var lastStoredValue: String?
    private(set) var storeCount = 0
    private(set) var clearCount = 0
    private(set) var lastPolicy: SandboxOfferCodeClipboardPolicy?

    init(trace: SandboxOfferCodeTestTrace) {
        self.trace = trace
    }

    func store(
        _ value: String,
        policy: SandboxOfferCodeClipboardPolicy
    ) -> Int {
        lastStoredValue = value
        lastPolicy = policy
        changeCount += 1
        storeCount += 1
        trace.entries.append("store")
        return changeCount
    }

    func clearIfUnchanged(after expectedChangeCount: Int) {
        guard expectedChangeCount == changeCount else { return }
        changeCount += 1
        clearCount += 1
        trace.entries.append("clear")
    }

    func matchesLastStoredValue(_ expectedValue: String) -> Bool {
        lastStoredValue == expectedValue
    }
}

@MainActor
private struct SandboxOfferCodeModelTestContext {
    let model: PaymentKitExampleModel
    let storageDirectoryURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: storageDirectoryURL)
    }
}

/// 直接验证 App Store Connect 返回的原生 StoreKit 定价数据。
///
/// 此测试不创建购买，仅用于 `Examples Sandbox` 真机方案定位 storefront 与商品配置。
final class SandboxStoreKitProbeTests: XCTestCase {
    /// 验证整机重启后，真实 Sandbox 仍自动返回永久解锁当前权益。
    func testCurrentSandboxEntitlementsSurviveDeviceReboot() async {
        var verifiedTransactions: [Transaction] = []
        var unverifiedDiagnostics: [String] = []

        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                verifiedTransactions.append(transaction)
            case .unverified(let transaction, let error):
                unverifiedDiagnostics.append(
                    "\(transaction.productID):\(error.localizedDescription)"
                )
            }
        }

        let verifiedDiagnostics = verifiedTransactions.map { transaction in
            if #available(iOS 16.0, macOS 13.0, *) {
                return "\(transaction.productID):\(transaction.environment.rawValue)"
            }
            return "\(transaction.productID):environment-unavailable"
        }
        let diagnostics = [
            "verified=\(verifiedDiagnostics.joined(separator: ","))",
            "unverified=\(unverifiedDiagnostics.joined(separator: ","))",
        ].joined(separator: "; ")
        print("PaymentKit StoreKit entitlement probe: \(diagnostics)")

        XCTAssertTrue(
            unverifiedDiagnostics.isEmpty,
            "真实 Sandbox 当前权益不得出现验签失败：\(diagnostics)"
        )
        XCTAssertTrue(
            verifiedTransactions.contains {
                $0.productID == "paymentkit.demo.lifetime"
            },
            "整机重启后，真实 Sandbox 必须自动返回永久解锁权益：\(diagnostics)"
        )
        if #available(iOS 16.0, macOS 13.0, *) {
            XCTAssertTrue(
                verifiedTransactions.allSatisfy { $0.environment == .sandbox },
                "Sandbox 探针不得混入 Xcode 本地 StoreKit 交易：\(diagnostics)"
            )
        } else {
            XCTFail("当前系统无法验证 StoreKit 交易环境：\(diagnostics)")
        }
    }

    /// 验证当前商店会返回年订阅的月付 12 个月承诺计划。
    func testCurrentStoreReturnsAnnualMonthlyCommitmentPricing() async throws {
        guard #available(iOS 26.4, macOS 26.4, *) else {
            XCTFail("当前系统不支持 StoreKit 月付 12 个月承诺计划")
            return
        }

        let storefront = await Storefront.current
        let products = try await Product.products(for: ["paymentkit.demo.yearly"])
        let product = try XCTUnwrap(products.first)
        let subscription = try XCTUnwrap(product.subscription)
        let rawPlans = subscription.pricingTerms.map {
            "\($0.billingPlanType.rawValue):\($0.billingDisplayPrice):\($0.commitmentInfo.displayPrice)"
        }
        let diagnostics = [
            "storefront=\(storefront?.countryCode ?? "nil")",
            "productPrice=\(product.displayPrice)",
            "plans=\(rawPlans.joined(separator: ","))",
        ].joined(separator: "; ")
        print("PaymentKit StoreKit probe: \(diagnostics)")

        XCTAssertEqual(
            storefront?.countryCode,
            "CHN",
            "Sandbox 真机探针必须使用目标中国区商店：\(diagnostics)"
        )
        XCTAssertEqual(
            product.displayPrice,
            "¥198.00",
            "Sandbox 真机探针不得回退到 Xcode 本地 StoreKit 定价：\(diagnostics)"
        )
        XCTAssertTrue(
            subscription.pricingTerms.contains {
                $0.billingPlanType == .monthly
                    && $0.billingDisplayPrice == "¥18.00"
                    && $0.commitmentInfo.displayPrice == "¥216.00"
            },
            diagnostics
        )
    }

    /// 验证没有订阅组购买历史的真实 Sandbox 账号能收到各账单方案的首购元数据。
    ///
    /// 此测试只读取 StoreKit 商品，不创建购买；首购资格应在实际购买前运行。
    func testFreshSandboxAccountReturnsIntroductoryOfferMetadata() async throws {
        guard #available(iOS 26.4, macOS 26.4, *) else {
            XCTFail("当前系统不支持按账单方案读取首购优惠")
            return
        }

        let productIDs = [
            "paymentkit.demo.monthly",
            "paymentkit.demo.yearly",
        ]
        let products = try await Product.products(for: productIDs)
        XCTAssertEqual(
            Set(products.map(\.id)),
            Set(productIDs),
            "真实 Sandbox 必须返回月订阅与年订阅商品"
        )

        var eligibilityByProductID: [String: Bool] = [:]
        var planDiagnosticsByProductID: [String: [String]] = [:]

        for product in products {
            let subscription = try XCTUnwrap(product.subscription)
            eligibilityByProductID[product.id] =
                await subscription.isEligibleForIntroOffer
            planDiagnosticsByProductID[product.id] =
                subscription.pricingTerms.map { terms in
                    let offers = terms.subscriptionOffers.map { offer in
                        [
                            "type=\(offer.type.rawValue)",
                            "mode=\(offer.paymentMode.rawValue)",
                            "price=\(offer.displayPrice)",
                            "period=\(offer.period.value)-\(String(describing: offer.period.unit))",
                            "count=\(offer.periodCount)",
                        ].joined(separator: "/")
                    }
                    return [
                        "plan=\(terms.billingPlanType.rawValue)",
                        "billing=\(terms.billingDisplayPrice)",
                        "commitment=\(terms.commitmentInfo.displayPrice)",
                        "offers=[\(offers.joined(separator: ","))]",
                    ].joined(separator: "/")
                }
        }

        let diagnostics = productIDs.map { productID in
            let eligibility = eligibilityByProductID[productID]
                .map(String.init) ?? "missing"
            let plans = planDiagnosticsByProductID[productID, default: []]
                .joined(separator: ";")
            return "\(productID){eligible=\(eligibility); \(plans)}"
        }.joined(separator: " | ")
        print("PaymentKit StoreKit introductory-offer probe: \(diagnostics)")

        XCTAssertEqual(
            eligibilityByProductID["paymentkit.demo.monthly"],
            true,
            "全新 Sandbox 账号必须具备月订阅首购资格：\(diagnostics)"
        )
        XCTAssertEqual(
            eligibilityByProductID["paymentkit.demo.yearly"],
            true,
            "同一订阅组的全新 Sandbox 账号必须具备年订阅首购资格：\(diagnostics)"
        )

        let monthlyOffers = try XCTUnwrap(
            products.first { $0.id == "paymentkit.demo.monthly" }?
                .subscription?
                .pricingTerms
                .flatMap(\.subscriptionOffers)
        )
        XCTAssertTrue(
            monthlyOffers.contains {
                $0.type == .introductory && $0.paymentMode == .freeTrial
            },
            "月订阅必须返回免费试用首购元数据：\(diagnostics)"
        )

        let yearlyUpFrontTerms = try XCTUnwrap(
            products.first { $0.id == "paymentkit.demo.yearly" }?
                .subscription?
                .pricingTerms
                .first { $0.billingPlanType == .upFront }
        )
        XCTAssertTrue(
            yearlyUpFrontTerms.subscriptionOffers.contains {
                $0.type == .introductory
                    && $0.paymentMode == .payUpFront
                    && $0.displayPrice == "¥148.00"
            },
            "预付年订阅必须返回首年 ¥148.00 优惠元数据：\(diagnostics)"
        )
    }
}

private struct TestContext {
    let session: SKTestSession
    let client: PaymentClient
    let processor: RecordingProcessor
    let storageDirectoryURL: URL

    /// 清理 StoreKit 会话及其隔离 outbox，避免测试状态泄漏到后续用例。
    func cleanup() {
        session.clearTransactions()
        try? FileManager.default.removeItem(at: storageDirectoryURL)
    }

    /// 在作用域结束时可靠停止监听，防止上一个 StoreKit 会话消费下一用例的交易。
    func withStartedClient<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        await client.start()
        do {
            let result = try await operation()
            await client.stop()
            return result
        } catch {
            await client.stop()
            throw error
        }
    }
}

private actor RecordingProcessor: TransactionProcessor {
    private var processedTransactions: [PaymentTransaction] = []

    func process(_ transaction: PaymentTransaction) async throws {
        processedTransactions.append(transaction)
    }

    func productIDs() -> [String] {
        processedTransactions.map(\.productID)
    }

    func processCount(for productID: String) -> Int {
        processedTransactions.count { $0.productID == productID }
    }

    func transactions(for productID: String) -> [PaymentTransaction] {
        processedTransactions.filter { $0.productID == productID }
    }
}

private actor FailingOnceProcessor: TransactionProcessor {
    private(set) var processCount = 0

    func process(_ transaction: PaymentTransaction) async throws {
        processCount += 1
        if processCount == 1 {
            throw MockProcessingError.failed
        }
    }
}

private enum MockProcessingError: Error {
    case failed
}
