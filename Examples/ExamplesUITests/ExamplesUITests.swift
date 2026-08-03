import XCTest

/// 验证示例程序的关键人工测试入口可以访问。
final class ExamplesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 验证应用启动后可以看到支付状态和模拟后台控制项。
    @MainActor
    func testPaymentDashboardLaunches() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["backend-online-toggle"].exists)

        let productIDs = [
            "paymentkit.demo.coins100",
            "paymentkit.demo.lifetime",
            "paymentkit.demo.monthly",
            "paymentkit.demo.yearly",
        ]
        for productID in productIDs {
            let productLabel = app.staticTexts[productID]
            var remainingProductScrollAttempts = 8
            while !productLabel.exists, remainingProductScrollAttempts > 0 {
                // 商品位于按顺序加载的长列表中；逐项滚动可同时验证真实 Sandbox 返回结果。
                app.swipeUp()
                remainingProductScrollAttempts -= 1
            }
            XCTAssertTrue(
                productLabel.waitForExistence(timeout: 2),
                "未在真机界面找到商品 \(productID)"
            )
        }

        let restoreButton = app.buttons["restore-button"]
        var remainingScrollAttempts = 8
        while !restoreButton.exists, remainingScrollAttempts > 0 {
            // “恢复购买”位于长列表下方；滚动后 SwiftUI 才会创建对应的可访问性元素。
            app.swipeUp()
            remainingScrollAttempts -= 1
        }
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 2))
    }

    /// 验证 Sandbox 返回首购、促销和月付承诺计划的真实展示数据。
    @MainActor
    func testSandboxSubscriptionPricingAndOffers() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let monthlyProduct = app.staticTexts["paymentkit.demo.monthly"]
        scroll(app, until: monthlyProduct)
        XCTAssertTrue(monthlyProduct.waitForExistence(timeout: 2))

        let promotionalOffer = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "pk_monthly_promo_099_2m_2026"
            )
        ).firstMatch
        scroll(app, until: promotionalOffer, maximumAttempts: 4)
        XCTAssertTrue(
            promotionalOffer.waitForExistence(timeout: 2),
            "真实 Sandbox 商品未返回月订阅促销优惠"
        )

        let introductoryOffer = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "免费试用",
                "当前账户不符合该订阅组首购优惠资格"
            )
        ).firstMatch
        XCTAssertTrue(
            introductoryOffer.waitForExistence(timeout: 2),
            "真实 Sandbox 商品未返回月订阅首购优惠状态"
        )

        let yearlyProduct = app.staticTexts["paymentkit.demo.yearly"]
        scroll(app, until: yearlyProduct)
        XCTAssertTrue(yearlyProduct.waitForExistence(timeout: 2))

        // SwiftUI 分段选择器在不同 iOS 版本可能暴露为 Button 或其他可访问性元素；
        // 使用稳定标识定位，同时继续严格验证真实账单数据。
        let commitmentPlan = app.descendants(matching: .any)[
            "billing-plan-paymentkit.demo.yearly-monthly-commitment"
        ]
        scroll(app, until: commitmentPlan, maximumAttempts: 4)
        XCTAssertTrue(
            commitmentPlan.waitForExistence(timeout: 2),
            "真实 Sandbox 商品未返回月付 12 个月承诺计划"
        )

        commitmentPlan.tap()

        let commitmentDisclosure = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "总承诺")
        ).firstMatch
        XCTAssertTrue(
            commitmentDisclosure.waitForExistence(timeout: 2),
            "选择承诺计划后未展示总承诺金额和期限"
        )
    }

    /// 验证已过期 Sandbox 订阅账号可以选择促销优惠，但不会直接发起购买。
    @MainActor
    func testExpiredSandboxAccountCanSelectMonthlyPromotionalOfferWithoutPurchase()
        throws
    {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let monthlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyState, maximumAttempts: 8)
        XCTAssertTrue(monthlyState.waitForExistence(timeout: 30))
        XCTAssertEqual(
            monthlyState.label,
            "已过期",
            "测试前置不满足：当前 Sandbox 账号必须已有一段已过期的月订阅历史"
        )

        let offerPicker = app.descendants(matching: .any)[
            "purchase-offer-paymentkit.demo.monthly"
        ]
        scrollDown(app, until: offerPicker)
        XCTAssertTrue(offerPicker.waitForExistence(timeout: 2))
        offerPicker.tap()

        let promotionalOffer = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@",
                "促销优惠 · pk_monthly_promo_099_2m_2026"
            )
        ).firstMatch
        XCTAssertTrue(
            promotionalOffer.waitForExistence(timeout: 2),
            "已过期订阅账号必须能从真实 Sandbox 商品选择月订阅促销优惠"
        )
        promotionalOffer.tap()

        let purchaseButton = app.buttons["purchase-paymentkit.demo.monthly"]
        scroll(app, untilHittable: purchaseButton, maximumAttempts: 4)
        XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))
        XCTAssertEqual(
            purchaseButton.label,
            "使用促销优惠",
            "选择促销优惠后主操作不得静默降级为标准价格购买"
        )

        let authorizationField = app.descendants(matching: .any)[
            "促销 compact JWS（仅保存在内存）"
        ]
        XCTAssertTrue(
            authorizationField.waitForExistence(timeout: 2),
            "促销购买前必须明确要求生产后台签发的 compact JWS"
        )
    }

    /// 严格验证没有同订阅组购买历史的 Sandbox 账号仍具备两项首购资格。
    ///
    /// 该用例只读取并切换展示方案，不点击购买按钮。完成任一订阅购买后，同一
    /// 账号不应再用于此测试。
    @MainActor
    func testFreshSandboxAccountIntroductoryOfferEligibility() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let monthlyPurchaseButton = app.buttons[
            "purchase-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyPurchaseButton)
        XCTAssertTrue(monthlyPurchaseButton.waitForExistence(timeout: 2))
        XCTAssertEqual(
            monthlyPurchaseButton.label,
            "免费试用",
            "全新 Sandbox 账号的月订阅必须提供 7 天免费试用"
        )

        let ineligibleMessage = app.staticTexts[
            "当前账户不符合该订阅组首购优惠资格"
        ]
        XCTAssertFalse(
            ineligibleMessage.exists,
            "全新 Sandbox 账号不得被标记为不符合首购优惠资格"
        )

        let yearlyUpFrontPlan = app.descendants(matching: .any)[
            "billing-plan-paymentkit.demo.yearly-up-front"
        ]
        scroll(app, until: yearlyUpFrontPlan, maximumAttempts: 4)
        XCTAssertTrue(yearlyUpFrontPlan.waitForExistence(timeout: 2))
        yearlyUpFrontPlan.tap()

        let yearlyIntroductoryOffer = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "首购",
                "¥148.00"
            )
        ).firstMatch
        XCTAssertTrue(
            yearlyIntroductoryOffer.waitForExistence(timeout: 2),
            "全新 Sandbox 账号的预付年订阅必须展示首年 ¥148.00 优惠"
        )

        let yearlyPurchaseButton = app.buttons[
            "purchase-paymentkit.demo.yearly"
        ]
        XCTAssertEqual(
            yearlyPurchaseButton.label,
            "¥148.00",
            "预付年订阅主操作必须展示 StoreKit 将实际结算的首购价格"
        )
    }

    /// 验证全新 Sandbox 账号的月订阅免费试用能完成交付并在冷启动后恢复。
    ///
    /// 测试只点击示例程序中的购买入口；Apple 系统购买页必须由测试人员在真机
    /// 上确认。完成购买后，同一账号不应再用于首购资格前置测试。
    @MainActor
    func testFreshSandboxMonthlyIntroductoryPurchaseConvergesAndSurvivesRelaunch()
        throws
    {
        let app = XCUIApplication()
        app.launchArguments.append("-PaymentKitStoreKitRuntimeProbe")
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["运行时当前权益：无"].waitForExistence(timeout: 10),
            "测试前置不满足：全新 Sandbox 账号不得已有当前权益"
        )

        let signedEventCount = app.staticTexts["backend-signed-event-count"]
        let businessDeliveryCount = app.staticTexts[
            "backend-business-delivery-count"
        ]
        let initialSignedEventCount = try integerLabel(
            of: signedEventCount,
            timeout: 10,
            failureMessage: "购买前必须能读取共享签名事件计数"
        )
        let initialBusinessDeliveryCount = try integerLabel(
            of: businessDeliveryCount,
            timeout: 10,
            failureMessage: "购买前必须能读取业务交付计数"
        )

        let purchaseButton = app.buttons["purchase-paymentkit.demo.monthly"]
        scroll(app, untilHittable: purchaseButton)
        XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))
        XCTAssertTrue(purchaseButton.isHittable)
        XCTAssertEqual(
            purchaseButton.label,
            "免费试用",
            "实际购买前必须再次证明月订阅将使用 7 天免费试用"
        )
        purchaseButton.tap()

        XCTAssertTrue(
            waitForSandboxPurchasePresentationRoundTrip(
                application: app,
                timeout: 180
            ),
            "请在 Apple Sandbox 系统购买页确认月订阅免费试用并返回应用"
        )

        assertMonthlyIntroductoryEntitlement(in: app)

        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "月订阅首购完成后不应遗留等待交付或 finish 的交易"
        )

        scrollDown(app, until: signedEventCount)
        let deliveredSignedEventCount = try XCTUnwrap(
            waitForIntegerLabel(
                of: signedEventCount,
                atLeast: initialSignedEventCount + 1,
                timeout: 30
            ),
            "月订阅首购必须至少产生一个已验签后台事件"
        )
        let deliveredBusinessCount = try XCTUnwrap(
            waitForIntegerLabel(
                of: businessDeliveryCount,
                atLeast: initialBusinessDeliveryCount + 1,
                timeout: 30
            ),
            "月订阅首购必须至少完成一次业务交付"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertMonthlyIntroductoryEntitlement(in: app)

        let relaunchedPendingCount = app.staticTexts["pending-transactions-count"]
        scroll(app, until: relaunchedPendingCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedPendingCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "冷启动后不应重新产生等待交付或 finish 的交易"
        )

        let relaunchedSignedEventCount = app.staticTexts[
            "backend-signed-event-count"
        ]
        scrollDown(app, until: relaunchedSignedEventCount)
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedSignedEventCount,
                equalTo: "\(deliveredSignedEventCount)",
                timeout: 10
            ),
            "冷启动不得重复记录同一笔月订阅首购签名事件"
        )
        XCTAssertTrue(
            waitForLabel(
                of: app.staticTexts["backend-business-delivery-count"],
                equalTo: "\(deliveredBusinessCount)",
                timeout: 10
            ),
            "冷启动不得重复交付同一笔月订阅首购业务状态"
        )
    }

    /// 为账单失败真机探针重新购买一段月订阅，不依赖首购优惠资格。
    ///
    /// 该用例要求当前没有月订阅权益；有历史时必须已经过期，Sandbox 不返回
    /// 月订阅历史节点时也可从无权益状态开始。测试只点击应用内购买入口；Apple
    /// 系统购买页仍由测试人员确认。购买返回后验证有效权益、自动续订、后台交付
    /// 和 pending 均已收敛，但不做冷启动，以便测试人员能在下一次三分钟续订前
    /// 关闭 Sandbox 的 Purchases & Renewals。
    @MainActor
    func testSandboxMonthlyRepurchaseConvergesForBillingFailureProbe() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-PaymentKitStoreKitRuntimeProbe")
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let monthlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyState, maximumAttempts: 8)
        if monthlyState.exists {
            XCTAssertEqual(
                monthlyState.label,
                "已过期",
                "测试前置不满足：已有月订阅历史时必须处于已过期状态"
            )
        }
        XCTAssertFalse(
            app.staticTexts["entitlement-paymentkit.demo.monthly"].exists,
            "测试前置不满足：重新购买前不得仍持有月订阅权益"
        )

        let signedEventCount = app.staticTexts["backend-signed-event-count"]
        let businessDeliveryCount = app.staticTexts[
            "backend-business-delivery-count"
        ]
        scrollDown(app, until: signedEventCount)
        let initialSignedEventCount = try integerLabel(
            of: signedEventCount,
            timeout: 10,
            failureMessage: "复购前必须能读取共享签名事件计数"
        )
        let initialBusinessDeliveryCount = try integerLabel(
            of: businessDeliveryCount,
            timeout: 10,
            failureMessage: "复购前必须能读取业务交付计数"
        )

        let purchaseButton = app.buttons["purchase-paymentkit.demo.monthly"]
        scroll(app, untilHittable: purchaseButton)
        XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))
        XCTAssertTrue(purchaseButton.isHittable)
        purchaseButton.tap()

        XCTAssertTrue(
            waitForSandboxPurchasePresentationRoundTrip(
                application: app,
                timeout: 180
            ),
            "请在 Apple Sandbox 系统购买页确认月订阅并返回应用"
        )

        let monthlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyEntitlement, maximumAttempts: 6)
        XCTAssertTrue(
            monthlyEntitlement.waitForExistence(timeout: 120),
            "Sandbox 复购返回后，月订阅权益应自动出现"
        )

        scroll(app, until: monthlyState, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(of: monthlyState, equalTo: "有效", timeout: 30),
            "Sandbox 复购返回后，月订阅状态应自动收敛为有效"
        )
        XCTAssertTrue(
            waitForLabel(
                of: app.staticTexts[
                    "auto-renew-status-paymentkit.demo.monthly"
                ],
                equalTo: "将自动续订",
                timeout: 30
            ),
            "账单失败探针开始前，月订阅必须处于自动续订状态"
        )

        let pendingTransactionsCount = app.staticTexts[
            "pending-transactions-count"
        ]
        // 无权益分支会先向列表顶部寻找运行时探针；pending 区域位于其下方，
        // 此处必须改为向下浏览列表，不能继续向顶部滚动造成元素永远未创建。
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 8)
        XCTAssertTrue(
            pendingTransactionsCount.waitForExistence(timeout: 10),
            "必须能访问待处理交易状态区域"
        )
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "月订阅复购完成后不应遗留等待交付或 finish 的交易"
        )

        scrollDown(app, until: signedEventCount)
        XCTAssertNotNil(
            waitForIntegerLabel(
                of: signedEventCount,
                atLeast: initialSignedEventCount + 1,
                timeout: 30
            ),
            "月订阅复购必须至少产生一个已验签后台事件"
        )
        XCTAssertNotNil(
            waitForIntegerLabel(
                of: businessDeliveryCount,
                atLeast: initialBusinessDeliveryCount + 1,
                timeout: 30
            ),
            "月订阅复购必须至少完成一次业务交付"
        )
    }

    /// 只读采样关闭 Sandbox 购买与续订后的月订阅失败状态。
    ///
    /// 宽限期内权益必须继续存在；进入账单重试或最终过期后权益必须撤回。
    /// 用例不点击诊断刷新，也不修改任何系统订阅设置。
    @MainActor
    func testSandboxMonthlyBillingFailureStateReadOnly() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-PaymentKitStoreKitRuntimeProbe")
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let monthlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyState, maximumAttempts: 8)
        XCTAssertTrue(
            monthlyState.waitForExistence(timeout: 120),
            "关闭 Sandbox 续订后必须保留可观测的月订阅生命周期状态"
        )

        let observedState = monthlyState.label
        XCTContext.runActivity(named: "月订阅失败状态：\(observedState)") { _ in }
        XCTAssertTrue(
            ["宽限期", "账单重试", "已过期"].contains(observedState),
            "续订失败后的月订阅必须处于宽限期、账单重试或已过期，实际为 \(observedState)"
        )

        let monthlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.monthly"
        ]
        scrollDown(app, until: monthlyEntitlement, maximumAttempts: 6)
        if observedState == "宽限期" {
            XCTAssertTrue(
                monthlyEntitlement.waitForExistence(timeout: 30),
                "宽限期内必须保留月订阅当前权益"
            )
        } else {
            XCTAssertFalse(
                monthlyEntitlement.exists,
                "进入账单重试或过期后不得继续保留月订阅当前权益"
            )
            XCTAssertTrue(
                app.staticTexts["运行时当前权益：无"].waitForExistence(
                    timeout: 30
                ),
                "账单重试或过期后 StoreKit 当前权益集合应为空"
            )
        }

        let pendingTransactionsCount = app.staticTexts[
            "pending-transactions-count"
        ]
        // 无权益分支会先向列表顶部寻找运行时探针；pending 区域位于其下方，
        // 此处必须改为向下浏览列表，不能继续向顶部滚动造成元素永远未创建。
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 8)
        XCTAssertTrue(
            pendingTransactionsCount.waitForExistence(timeout: 10),
            "必须能访问待处理交易状态区域"
        )
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "失败续订不得被误留为等待交付或 finish 的成功交易"
        )
    }

    /// 只读验证重新允许 Sandbox 续订后，月订阅恢复并保持幂等冷启动。
    ///
    /// 用例不修改系统设置，也不发起购买或恢复同步。恢复交易必须已经通过正常
    /// StoreKit 更新到达；第二次冷启动用于证明同一恢复状态不会重复交付。
    @MainActor
    func testSandboxMonthlyBillingRecoverySurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-PaymentKitStoreKitRuntimeProbe")
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        try assertSandboxMonthlyBillingRecoveryState(in: app)

        let signedEventCount = app.staticTexts["backend-signed-event-count"]
        let businessDeliveryCount = app.staticTexts[
            "backend-business-delivery-count"
        ]
        scrollDown(app, until: signedEventCount)
        let recoveredSignedEventCount = try integerLabel(
            of: signedEventCount,
            timeout: 10,
            failureMessage: "账单恢复后必须能读取共享签名事件计数"
        )
        let recoveredBusinessDeliveryCount = try integerLabel(
            of: businessDeliveryCount,
            timeout: 10,
            failureMessage: "账单恢复后必须能读取业务交付计数"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        try assertSandboxMonthlyBillingRecoveryState(in: app)

        let relaunchedSignedEventCount = app.staticTexts[
            "backend-signed-event-count"
        ]
        scrollDown(app, until: relaunchedSignedEventCount)
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedSignedEventCount,
                equalTo: "\(recoveredSignedEventCount)",
                timeout: 10
            ),
            "冷启动不得重复记录同一笔账单恢复签名事件"
        )
        XCTAssertTrue(
            waitForLabel(
                of: app.staticTexts["backend-business-delivery-count"],
                equalTo: "\(recoveredBusinessDeliveryCount)",
                timeout: 10
            ),
            "冷启动不得重复交付同一笔账单恢复业务状态"
        )
    }

    /// 短路径验证启动重放完成后 pending 立即归零并经受一次冷启动。
    ///
    /// 不读取订阅权益和续订状态，避免 3 分钟 Sandbox 续订边界在长列表滚动期间
    /// 把下一笔合法新交易混入账单恢复断言。
    @MainActor
    func testSandboxPendingConvergesAfterColdLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertSandboxPendingTransactionsAreZero(in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertSandboxPendingTransactionsAreZero(in: app)
    }

    /// 单次启动只读采样月订阅状态，供 3 分钟 Sandbox 边界前置判断使用。
    @MainActor
    func testSandboxMonthlyLifecycleSnapshotReadOnly() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let monthlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyState, maximumAttempts: 8)
        XCTAssertTrue(monthlyState.waitForExistence(timeout: 30))

        let renewalStatus = app.staticTexts[
            "auto-renew-status-paymentkit.demo.monthly"
        ]
        XCTAssertTrue(renewalStatus.waitForExistence(timeout: 10))
        let observedState = monthlyState.label
        let observedRenewalStatus = renewalStatus.label

        let monthlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.monthly"
        ]
        scrollDown(app, until: monthlyEntitlement, maximumAttempts: 6)
        let hasMonthlyEntitlement = monthlyEntitlement.exists

        let pendingTransactionsCount = app.staticTexts[
            "pending-transactions-count"
        ]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 8)
        XCTAssertTrue(pendingTransactionsCount.waitForExistence(timeout: 10))
        let observedPending = pendingTransactionsCount.label

        XCTContext.runActivity(
            named: "月订阅快照：\(observedState) / \(observedRenewalStatus) / 权益：\(hasMonthlyEntitlement ? "有" : "无") / \(observedPending)"
        ) { _ in }

        XCTAssertTrue(
            ["有效", "宽限期", "账单重试", "已过期", "已撤销"].contains(
                observedState
            )
        )
    }

    /// 验证年订阅可以从菜单选择脱敏优惠代码，并切换统一主操作文案。
    ///
    /// 测试不点击最终兑换按钮，避免打开系统兑换页或把完整代码写入测试日志。
    @MainActor
    func testYearlySandboxOfferCodeMenuSelectsSanitizedPrimaryAction() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-PaymentKitUITestSandboxOfferCodeCatalog")
        app.launchEnvironment[
            "PAYMENTKIT_UI_TEST_SANDBOX_OFFER_CODE_CATALOG"
        ] = "synthetic"
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let offerPicker = app.descendants(matching: .any)[
            "purchase-offer-paymentkit.demo.yearly"
        ]
        scroll(app, until: offerPicker)
        XCTAssertTrue(
            offerPicker.waitForExistence(timeout: 2),
            "年订阅必须展示可访问的购买优惠菜单"
        )

        let purchaseButton = app.buttons["purchase-paymentkit.demo.yearly"]
        XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))

        offerPicker.tap()
        let sanitizedCode = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@",
                "优惠代码 01 · ••••••••••••••ABCD"
            )
        ).firstMatch
        XCTAssertTrue(
            sanitizedCode.waitForExistence(timeout: 2),
            "优惠菜单必须使用测试注入的虚构脱敏代码，不得依赖实际 CSV 内容"
        )
        sanitizedCode.tap()

        scroll(app, untilHittable: purchaseButton)
        XCTAssertTrue(
            waitForLabel(
                of: purchaseButton,
                equalTo: "复制并兑换优惠代码",
                timeout: 2
            )
        )
        XCTAssertTrue(purchaseButton.isHittable)
    }

    /// 验证没有有效 Sandbox 代码时菜单展示不可选占位，并保留普通优惠路径。
    @MainActor
    func testYearlyOfferMenuShowsDisabledUnconfiguredPlaceholder() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-PaymentKitUITestSandboxOfferCodeCatalog")
        app.launchEnvironment[
            "PAYMENTKIT_UI_TEST_SANDBOX_OFFER_CODE_CATALOG"
        ] = "empty"
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let offerPicker = app.descendants(matching: .any)[
            "purchase-offer-paymentkit.demo.yearly"
        ]
        scroll(app, until: offerPicker)
        XCTAssertTrue(offerPicker.waitForExistence(timeout: 2))
        offerPicker.tap()

        let placeholder = app.descendants(matching: .any)[
            "sandbox-offer-code-unconfigured-placeholder"
        ]
        XCTAssertTrue(
            placeholder.waitForExistence(timeout: 2),
            "无有效代码时年订阅优惠菜单必须显示未配置占位"
        )
        XCTAssertEqual(placeholder.label, "未配置 Sandbox 优惠代码")
        XCTAssertFalse(placeholder.isEnabled, "未配置占位不能成为可选择 offer")

        let standardOffer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "标准价格")
        ).firstMatch
        XCTAssertTrue(standardOffer.waitForExistence(timeout: 2))
        XCTAssertTrue(standardOffer.isEnabled)
    }

    /// 验证购买完成后界面自动显示交付结果，不依赖诊断刷新按钮。
    ///
    /// Sandbox 运行时需要测试人员在 Apple 系统购买页确认交易；测试随后只等待
    /// PaymentKit 的购买与交易监听自动提交状态。
    @MainActor
    func testPurchaseConvergesWithoutManualRefresh() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let purchaseButton = app.buttons["purchase-paymentkit.demo.coins100"]
        scroll(app, until: purchaseButton)
        XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))
        purchaseButton.tap()

        XCTAssertTrue(
            waitForOperationRoundTrip(
                observedElement: purchaseButton,
                timeout: 120
            ),
            "请在 Apple 系统购买页完成或取消操作"
        )
        scrollDown(app, until: app.staticTexts["status-message"])
        XCTAssertTrue(
            waitForLabel(
                of: app.staticTexts["status-message"],
                beginningWith: "交易已交付并 finish：",
                timeout: 120
            ),
            "请确认系统购买页；完成后应用应自动显示交付结果，测试不会点击诊断刷新按钮"
        )
    }

    /// 验证永久解锁购买后自动授予权益，并且冷启动后仍然存在。
    ///
    /// 首次运行需要测试人员在 Apple Sandbox 系统页确认购买；账号已经持有
    /// 永久解锁时不会重复购买，只验证既有权益和可靠交付状态。
    @MainActor
    func testLifetimePurchaseConvergesAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let lifetimeEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.lifetime"
        ]
        scroll(app, until: lifetimeEntitlement, maximumAttempts: 3)

        if !lifetimeEntitlement.exists {
            let purchaseButton = app.buttons["purchase-paymentkit.demo.lifetime"]
            scrollDown(app, until: purchaseButton)
            XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))
            XCTAssertTrue(purchaseButton.isHittable)
            purchaseButton.tap()

            XCTAssertTrue(
                waitForOperationRoundTrip(
                    observedElement: purchaseButton,
                    timeout: 120
                ),
                "请在 Apple Sandbox 系统页确认永久解锁购买并返回应用"
            )
            scroll(app, until: lifetimeEntitlement)
            XCTAssertTrue(
                lifetimeEntitlement.waitForExistence(timeout: 120),
                "购买返回后永久解锁权益应自动出现"
            )
        }

        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "永久解锁购买后不应遗留等待交付或 finish 的交易"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertRestorableLifetimeEntitlement(in: app)
    }

    /// 验证真实 Sandbox 的月付 12 个月承诺交易会返回账单计划和承诺进度。
    ///
    /// 本地 StoreKit 测试环境可能不会把测试配置中的月付承诺选项写入交易，
    /// 因此该用例在真机 Sandbox 中直接验证生产路径，并在冷启动后再次确认。
    @MainActor
    func testYearlyMonthlyCommitmentPurchaseConvergesAndSurvivesRelaunch() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let yearlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyEntitlement, maximumAttempts: 3)

        if !yearlyEntitlement.exists {
            let monthlyCommitmentPlan = app.descendants(matching: .any)[
                "billing-plan-paymentkit.demo.yearly-monthly-commitment"
            ]
            scrollDown(app, until: monthlyCommitmentPlan)
            XCTAssertTrue(
                monthlyCommitmentPlan.waitForExistence(timeout: 2),
                "真实 Sandbox 年订阅必须提供月付 12 个月承诺方案"
            )
            monthlyCommitmentPlan.tap()

            let purchaseButton = app.buttons["purchase-paymentkit.demo.yearly"]
            scroll(app, untilHittable: purchaseButton, maximumAttempts: 4)
            XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))
            XCTAssertTrue(purchaseButton.isHittable)
            purchaseButton.tap()

            XCTAssertTrue(
                waitForSystemPresentationRoundTrip(
                    observedElement: purchaseButton,
                    timeout: 180
                ),
                "请在 Apple Sandbox 购买页确认月付 12 个月承诺订阅并返回应用"
            )
        }

        assertYearlyMonthlyCommitmentEntitlement(in: app)

        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "月付承诺购买后应自动完成业务交付和 finish"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertYearlyMonthlyCommitmentEntitlement(in: app)
    }

    /// 验证关闭月付承诺的下一轮续期后，当前剩余分期与下一承诺被正确区分。
    @MainActor
    func testYearlyMonthlyCommitmentCancellationConvergesAndSurvivesRelaunch() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertYearlyMonthlyCommitmentEntitlement(in: app)

        let periodStatus = app.staticTexts[
            "auto-renew-status-paymentkit.demo.yearly"
        ]
        scroll(app, until: periodStatus)
        XCTAssertTrue(
            waitForLabel(
                of: periodStatus,
                beginningWith: "当前承诺：",
                timeout: 30
            ),
            "月付承诺必须独立展示当前 12 个月承诺的分期状态"
        )

        let commitmentStatus = app.staticTexts[
            "commitment-renewal-status-paymentkit.demo.yearly"
        ]
        XCTAssertTrue(commitmentStatus.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForLabel(
                of: commitmentStatus,
                equalTo: "下一承诺：将自动续期",
                timeout: 30
            ),
            "测试前置不满足：新购月付承诺必须正在续期下一轮承诺"
        )

        let manageButton = app.buttons["manage-subscriptions-button"]
        scrollDown(app, until: manageButton)
        XCTAssertTrue(manageButton.waitForExistence(timeout: 2))
        manageButton.tap()

        XCTAssertTrue(
            waitForOperationRoundTrip(
                observedElement: manageButton,
                timeout: 180
            ),
            "请在 Apple 系统订阅管理页取消下一轮 12 个月承诺并返回应用"
        )

        assertYearlyMonthlyCommitmentCancellationState(in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertYearlyMonthlyCommitmentCancellationState(in: app)
    }

    /// 验证下一承诺取消后，当前承诺完成全部分期并最终自动到期。
    @MainActor
    func testYearlyMonthlyCommitmentCancellationEventuallyExpires() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertRestorableLifetimeEntitlement(in: app)

        let yearlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyState)
        XCTAssertTrue(yearlyState.waitForExistence(timeout: 10))
        if yearlyState.label != "已过期" {
            assertYearlyMonthlyCommitmentCancellationState(in: app)
            scroll(app, until: yearlyState)
            XCTAssertTrue(
                waitForLabel(
                    of: yearlyState,
                    equalTo: "已过期",
                    timeout: 600
                ),
                "下一承诺取消后，当前月付承诺完成全部 12 期后必须自动到期"
            )
        }

        assertExpiredYearlyMonthlyCommitmentState(in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        assertRestorableLifetimeEntitlement(in: app)
        assertExpiredYearlyMonthlyCommitmentState(in: app)
    }

    /// 验证用户主动恢复完成后，界面直接采用恢复快照而无需诊断刷新。
    ///
    /// 恢复购买是唯一允许触发 `AppStore.sync()` 的流程；Sandbox 可能要求测试人员
    /// 在系统认证页完成登录。
    @MainActor
    func testRestoreConvergesWithoutManualRefresh() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let restoreButton = app.buttons["restore-button"]
        scroll(app, until: restoreButton)
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 2))
        restoreButton.tap()

        XCTAssertTrue(
            waitForOperationRoundTrip(
                observedElement: restoreButton,
                timeout: 120
            ),
            "请完成恢复购买所需的 Apple 系统认证"
        )

        let restoreFailureAlert = app.alerts["操作失败"]
        if restoreFailureAlert.waitForExistence(timeout: 2) {
            let dismissButton = restoreFailureAlert.buttons["好"]
            XCTAssertTrue(dismissButton.waitForExistence(timeout: 2))
            dismissButton.tap()

            let springboard = XCUIApplication(
                bundleIdentifier: "com.apple.springboard"
            )
            let appleAccountLogin = springboard.alerts["登录Apple账户"]
            XCTAssertTrue(
                appleAccountLogin.waitForExistence(timeout: 10),
                "恢复失败后应出现 Apple 账户登录页；若没有出现，则不是可重试的认证失败"
            )
            let loginCompleted = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: appleAccountLogin
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [loginCompleted], timeout: 180),
                .completed,
                "请在 Apple 系统页完成账户登录；测试不会代填凭据或点击取消"
            )

            restoreButton.tap()
            XCTAssertTrue(
                waitForOperationRoundTrip(
                    observedElement: restoreButton,
                    timeout: 120
                ),
                "Apple 账户登录完成后，恢复购买重试应正常返回"
            )
        }

        scrollDown(app, until: app.staticTexts["status-message"])
        XCTAssertTrue(
            waitForLabel(
                of: app.staticTexts["status-message"],
                equalTo: "App Store 同步与恢复已完成",
                timeout: 120
            ),
            "完成系统认证后，恢复结果应自动提交到界面，测试不会点击诊断刷新按钮"
        )

        // 该专用账号已由永久解锁购买用例证明持有非消耗型商品。恢复用例不能要求
        // 本地快照预先可见，否则无法覆盖重启或换机后需要恢复的真实场景。
        assertRestorableLifetimeEntitlement(in: app)
        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "恢复完成后应自动收敛为没有等待交付或 finish 的交易"
        )
    }

    /// 验证从订阅管理返回后，关闭自动续订的状态会自动显示。
    ///
    /// 该真机用例要求当前 Sandbox 账户存在有效订阅。测试人员在系统订阅管理页关闭
    /// 自动续订并返回后，测试只等待系统界面协调结果，不触发诊断刷新。
    @MainActor
    func testManageSubscriptionsReturnConvergesWithoutManualRefresh() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        // 先证明专用测试账号确实存在正在自动续订的订阅，避免已经关闭
        // 自动续订的账号直接命中最终文案而形成假绿。
        let monthlyStatuses = app.staticTexts.matching(
            identifier: "auto-renew-status-paymentkit.demo.monthly"
        )
        let monthlyRenewalStatus = monthlyStatuses.firstMatch
        scroll(app, until: monthlyRenewalStatus)
        XCTAssertEqual(
            monthlyStatuses.count, 1,
            "测试前必须恰好存在一个月订阅自动续订状态元素"
        )
        let monthlyRenewalIdentifier = monthlyRenewalStatus.identifier
        XCTAssertEqual(
            monthlyRenewalIdentifier,
            "auto-renew-status-paymentkit.demo.monthly",
            "测试前必须定位到月订阅产品作用域内的状态元素"
        )
        XCTAssertTrue(
            waitForLabel(
                of: monthlyRenewalStatus,
                equalTo: "将自动续订",
                timeout: 30
            ),
            "测试前置不满足：Sandbox 账号的月订阅必须正在自动续订"
        )

        let manageButton = app.buttons["manage-subscriptions-button"]
        scrollDown(app, until: manageButton)
        XCTAssertTrue(manageButton.waitForExistence(timeout: 2))
        manageButton.tap()

        XCTAssertTrue(
            waitForOperationRoundTrip(
                observedElement: manageButton,
                timeout: 180
            ),
            "请在 Apple 系统订阅管理页关闭自动续订并返回应用"
        )

        scroll(app, until: monthlyRenewalStatus)
        XCTAssertEqual(
            monthlyStatuses.count, 1,
            "系统订阅管理返回后仍必须恰好存在一个月订阅自动续订状态元素"
        )
        XCTAssertEqual(
            monthlyRenewalStatus.identifier,
            monthlyRenewalIdentifier,
            "系统订阅管理返回后必须仍定位到同一月订阅产品作用域标识"
        )
        XCTAssertTrue(
            waitForLabel(
                of: monthlyRenewalStatus,
                equalTo: "不会自动续订",
                timeout: 30
            ),
            "系统界面返回后，月订阅应自动刷新为不会自动续订，测试不会点击诊断刷新按钮"
        )
    }

    /// 只读验证月订阅关闭自动续订后的状态能在冷启动中恢复且不会重复交付。
    ///
    /// 该用例不会再次打开系统订阅管理页，也不会修改订阅。适用于测试人员已经在
    /// 系统页关闭月订阅自动续订后，验证最终 StoreKit 快照与后台幂等状态。
    @MainActor
    func testMonthlyAutoRenewOffStateSurvivesColdLaunchWithoutDuplicateDelivery()
        throws
    {
        let app = XCUIApplication()
        app.launchArguments.append("-PaymentKitStoreKitRuntimeProbe")
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        let initialState = assertMonthlyAutoRenewOffState(in: app)

        let pendingTransactionsCount = app.staticTexts[
            "pending-transactions-count"
        ]
        scrollDown(app, until: pendingTransactionsCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "关闭月订阅自动续订后不得遗留等待交付或 finish 的交易"
        )

        let signedEventCount = app.staticTexts["backend-signed-event-count"]
        let businessDeliveryCount = app.staticTexts[
            "backend-business-delivery-count"
        ]
        scrollDown(app, until: signedEventCount)
        let initialSignedEventCount = try integerLabel(
            of: signedEventCount,
            timeout: 10,
            failureMessage: "必须能读取关闭自动续订后的共享签名事件计数"
        )
        let initialBusinessDeliveryCount = try integerLabel(
            of: businessDeliveryCount,
            timeout: 10,
            failureMessage: "必须能读取关闭自动续订后的业务交付计数"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        let relaunchedState = assertMonthlyAutoRenewOffState(in: app)
        XCTAssertTrue(
            initialState == relaunchedState
                || (initialState == "有效" && relaunchedState == "已过期"),
            "关闭自动续订后的状态只能保持不变或从有效自然收敛为已过期"
        )

        let relaunchedPendingTransactionsCount = app.staticTexts[
            "pending-transactions-count"
        ]
        scrollDown(
            app,
            until: relaunchedPendingTransactionsCount,
            maximumAttempts: 4
        )
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedPendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "冷启动协调后不得遗留等待交付或 finish 的交易"
        )

        let relaunchedSignedEventCount = app.staticTexts[
            "backend-signed-event-count"
        ]
        scrollDown(app, until: relaunchedSignedEventCount)
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedSignedEventCount,
                equalTo: "\(initialSignedEventCount)",
                timeout: 10
            ),
            "冷启动不得重复记录关闭自动续订前已处理的签名事件"
        )
        XCTAssertTrue(
            waitForLabel(
                of: app.staticTexts["backend-business-delivery-count"],
                equalTo: "\(initialBusinessDeliveryCount)",
                timeout: 10
            ),
            "冷启动不得重复交付月订阅业务状态"
        )
    }

    /// 验证预付年订阅从购买到订阅管理返回后自动显示关闭续订的状态。
    ///
    /// 当前账号没有有效年订阅时，用例先固定选择年付预付方案并等待测试人员确认
    /// Sandbox 购买；已有有效权益时不会重复购买。随后测试人员在 Apple 系统页关闭
    /// 自动续订并返回，用例只等待自动协调，不点击诊断刷新。
    @MainActor
    func testYearlyUpFrontManageSubscriptionsReturnConvergesWithoutManualRefresh() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let yearlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyEntitlement)

        if !yearlyEntitlement.exists {
            let upFrontPlan = app.descendants(matching: .any)[
                "billing-plan-paymentkit.demo.yearly-up-front"
            ]
            scrollDown(app, until: upFrontPlan)
            XCTAssertTrue(
                upFrontPlan.waitForExistence(timeout: 2),
                "Sandbox 年订阅必须提供可选择的预付方案"
            )
            upFrontPlan.tap()

            let purchaseButton = app.buttons["purchase-paymentkit.demo.yearly"]
            scroll(app, untilHittable: purchaseButton, maximumAttempts: 4)
            XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))
            XCTAssertTrue(purchaseButton.isHittable)
            purchaseButton.tap()

            XCTAssertTrue(
                waitForSandboxPurchasePresentationRoundTrip(
                    application: app,
                    timeout: 180
                ),
                "请在 Apple Sandbox 购买页确认预付年订阅并返回应用"
            )

            scroll(app, until: yearlyEntitlement)
        }

        XCTAssertTrue(
            yearlyEntitlement.waitForExistence(timeout: 120),
            "Sandbox 购买返回后，年订阅权益应自动出现"
        )

        let upFrontBillingPlan = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "账单计划：预付")
        ).firstMatch
        scroll(app, until: upFrontBillingPlan, maximumAttempts: 4)
        XCTAssertTrue(
            upFrontBillingPlan.waitForExistence(timeout: 10),
            "当前年订阅交易必须映射为预付账单计划"
        )

        let yearlyStatuses = app.staticTexts.matching(
            identifier: "auto-renew-status-paymentkit.demo.yearly"
        )
        let yearlyRenewalStatus = yearlyStatuses.firstMatch
        scroll(app, until: yearlyRenewalStatus)
        XCTAssertEqual(
            yearlyStatuses.count, 1,
            "测试前必须恰好存在一个年订阅自动续订状态元素"
        )
        let yearlyRenewalIdentifier = yearlyRenewalStatus.identifier
        XCTAssertEqual(
            yearlyRenewalIdentifier,
            "auto-renew-status-paymentkit.demo.yearly",
            "测试前必须定位到年订阅产品作用域内的状态元素"
        )

        let manageButton = app.buttons["manage-subscriptions-button"]
        if !waitForLabel(
            of: yearlyRenewalStatus,
            equalTo: "将自动续订",
            timeout: 5
        ) {
            XCTAssertTrue(
                waitForLabel(
                    of: yearlyRenewalStatus,
                    equalTo: "不会自动续订",
                    timeout: 5
                ),
                "测试前置不满足：预付年订阅状态必须可识别"
            )

            scrollDown(app, until: manageButton)
            XCTAssertTrue(manageButton.waitForExistence(timeout: 2))
            manageButton.tap()

            XCTAssertTrue(
                waitForOperationRoundTrip(
                    observedElement: manageButton,
                    timeout: 180
                ),
                "请在 Apple 系统订阅管理页重新开启年订阅自动续订并返回应用"
            )

            scroll(app, until: yearlyRenewalStatus)
            XCTAssertTrue(
                waitForLabel(
                    of: yearlyRenewalStatus,
                    equalTo: "将自动续订",
                    timeout: 30
                ),
                "系统界面返回后，预付年订阅应自动刷新为将自动续订"
            )
        }

        XCTAssertTrue(
            waitForLabel(
                of: yearlyRenewalStatus,
                equalTo: "将自动续订",
                timeout: 30
            ),
            "测试前置不满足：预付年订阅必须正在自动续订"
        )

        scrollDown(app, until: manageButton)
        XCTAssertTrue(manageButton.waitForExistence(timeout: 2))
        manageButton.tap()

        XCTAssertTrue(
            waitForOperationRoundTrip(
                observedElement: manageButton,
                timeout: 180
            ),
            "请在 Apple 系统订阅管理页关闭年订阅自动续订并返回应用"
        )

        scroll(app, until: yearlyRenewalStatus)
        XCTAssertEqual(
            yearlyStatuses.count, 1,
            "系统订阅管理返回后仍必须恰好存在一个年订阅自动续订状态元素"
        )
        XCTAssertEqual(
            yearlyRenewalStatus.identifier,
            yearlyRenewalIdentifier,
            "系统订阅管理返回后必须仍定位到同一年订阅产品作用域标识"
        )
        XCTAssertTrue(
            waitForLabel(
                of: yearlyRenewalStatus,
                equalTo: "不会自动续订",
                timeout: 30
            ),
            "系统界面返回后，预付年订阅应自动刷新为不会自动续订，测试不会点击诊断刷新按钮"
        )
    }

    /// 验证已关闭自动续订的预付年订阅生命周期在冷启动后保持一致。
    ///
    /// 当前订阅可能仍有效，也可能已在 Sandbox 加速周期内到期。无论处于哪一
    /// 阶段，续订状态都必须保持为“不会自动续订”，重启不得倒退或遗留交易。
    @MainActor
    func testYearlyUpFrontCancellationLifecycleSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        let initialLifecycleState = assertYearlyUpFrontCancellationState(in: app)

        app.terminate()
        app.launch()
        XCTAssertEqual(
            assertYearlyUpFrontCancellationState(in: app),
            initialLifecycleState,
            "冷启动后年订阅生命周期状态不得倒退或改变"
        )
    }

    /// 只读确认退款目标是预付年订阅，还是按月付款的 12 个月承诺。
    ///
    /// 两种方案共用同一产品 ID，但扣款周期和退款影响不同；本用例不会打开退款页。
    @MainActor
    func testYearlyRefundPreflightCapturesBillingPlan() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let billingPlan = try assertYearlyRefundTargetBillingPlan(in: app)
        XCTContext.runActivity(named: "年度退款目标付款方式：\(billingPlan)") { _ in }
    }

    /// 为退款验收固定购买预付年订阅，并验证冷启动后付款方式不发生漂移。
    ///
    /// 月付 12 个月承诺具有独立的分期退款语义，不得作为本用例的替代方案。
    @MainActor
    func testYearlyUpFrontPurchaseConvergesForRefundProbe() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let yearlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyEntitlement, maximumAttempts: 8)
        XCTAssertFalse(
            yearlyEntitlement.exists,
            "测试前置不满足：购买预付年订阅前不得已有年订阅当前权益"
        )

        let upFrontPlan = app.descendants(matching: .any)[
            "billing-plan-paymentkit.demo.yearly-up-front"
        ]
        scrollDown(app, until: upFrontPlan, maximumAttempts: 10)
        XCTAssertTrue(
            upFrontPlan.waitForExistence(timeout: 10),
            "真实 Sandbox 年订阅必须提供预付方案"
        )
        upFrontPlan.tap()

        let purchaseButton = app.buttons["purchase-paymentkit.demo.yearly"]
        scroll(app, untilHittable: purchaseButton, maximumAttempts: 4)
        XCTAssertTrue(purchaseButton.waitForExistence(timeout: 2))
        XCTAssertTrue(purchaseButton.isHittable)
        purchaseButton.tap()

        XCTAssertTrue(
            waitForSandboxPurchasePresentationRoundTrip(
                application: app,
                timeout: 180
            ),
            "请在 Apple Sandbox 系统页确认预付年订阅并返回应用"
        )

        XCTAssertEqual(
            try assertYearlyRefundTargetBillingPlan(in: app),
            "账单计划：预付",
            "退款探针必须购买预付年订阅，不能误用月付 12 个月承诺"
        )

        let pendingTransactionsCount = app.staticTexts[
            "pending-transactions-count"
        ]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "预付年订阅购买后应自动完成业务交付和 finish"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            try assertYearlyRefundTargetBillingPlan(in: app),
            "账单计划：预付",
            "冷启动后预付年订阅付款方式不得漂移"
        )
    }

    /// 验证真实退款撤销会自动撤回年订阅权益，并且重启不会重复业务交付。
    ///
    /// 测试只打开 Apple 系统退款页；退款原因和最终提交必须由测试人员在真机上完成。
    /// 返回应用后不点击诊断刷新，直接等待 StoreKit 撤销状态、可靠交付和界面快照收敛。
    /// 退款按钮绑定当前权益交易：预付方案撤销当前年期；月付承诺方案撤销当前月期，
    /// Apple 随即结束当前承诺。历史月期退款不属于此测试，不能套用相同断言。
    @MainActor
    func testYearlyRefundRevocationConvergesWithoutManualRefresh() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let signedEventCount = app.staticTexts["backend-signed-event-count"]
        let businessDeliveryCount = app.staticTexts["backend-business-delivery-count"]
        let initialSignedEventCount = try integerLabel(
            of: signedEventCount,
            timeout: 10,
            failureMessage: "退款前必须能读取共享签名事件计数"
        )
        let initialBusinessDeliveryCount = try integerLabel(
            of: businessDeliveryCount,
            timeout: 10,
            failureMessage: "退款前必须能读取业务交付计数"
        )

        let yearlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyEntitlement)
        XCTAssertTrue(
            yearlyEntitlement.waitForExistence(timeout: 10),
            "测试前置不满足：Sandbox 账号必须持有有效年订阅权益"
        )
        let initialBillingPlan = try assertYearlyRefundTargetBillingPlan(in: app)
        XCTContext.runActivity(
            named: "年度退款目标付款方式：\(initialBillingPlan)"
        ) { _ in }

        let refundButton = app.buttons["refund-paymentkit.demo.yearly"]
        scroll(app, untilHittable: refundButton)
        XCTAssertTrue(
            refundButton.waitForExistence(timeout: 2),
            "年订阅权益必须提供产品作用域明确的退款入口"
        )
        XCTAssertTrue(refundButton.isHittable)
        refundButton.tap()

        let refundPresentationStarted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: refundButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [refundPresentationStarted], timeout: 10),
            .completed,
            "点击年订阅退款后必须进入系统界面协调状态"
        )

        let entitlementRevoked = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: yearlyEntitlement
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [entitlementRevoked], timeout: 300),
            .completed,
            "请在 Apple 系统退款页选择原因并提交；返回后年订阅权益应自动撤回"
        )

        let yearlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyState, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(of: yearlyState, equalTo: "已撤销", timeout: 60),
            "退款返回后订阅状态应自动刷新为已撤销"
        )

        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scrollDown(app, until: pendingTransactionsCount)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 60
            ),
            "退款撤销交易应完成后台交付与 StoreKit finish"
        )

        let signedEventAdvanced = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement,
                      let count = Int(element.label) else {
                    return false
                }
                return count >= initialSignedEventCount + 1
            },
            object: signedEventCount
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [signedEventAdvanced], timeout: 60),
            .completed,
            "退款撤销必须至少新增一个签名审计事件；StoreKit 可能对等价状态重新签名"
        )
        XCTAssertTrue(
            waitForLabel(
                of: businessDeliveryCount,
                equalTo: "\(initialBusinessDeliveryCount + 1)",
                timeout: 60
            ),
            "退款撤销必须恰好新增一次业务交付"
        )

        let revokedSignedEventCount = try integerLabel(
            of: signedEventCount,
            timeout: 2,
            failureMessage: "退款收敛后必须能读取共享签名事件计数"
        )
        let revokedBusinessDeliveryCount = try integerLabel(
            of: businessDeliveryCount,
            timeout: 2,
            failureMessage: "退款收敛后必须能读取业务交付计数"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let relaunchedYearlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.yearly"
        ]
        scroll(app, until: relaunchedYearlyState)
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedYearlyState,
                equalTo: "已撤销",
                timeout: 30
            ),
            "重启后年订阅仍应保持已撤销"
        )
        XCTAssertFalse(
            app.staticTexts["entitlement-paymentkit.demo.yearly"].exists,
            "重启后不得恢复已撤销的年订阅权益"
        )

        let relaunchedPendingCount = app.staticTexts["pending-transactions-count"]
        scrollDown(app, until: relaunchedPendingCount)
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedPendingCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "重启重放后仍应没有等待交付或 finish 的撤销交易"
        )
        let relaunchedSignedEventCount = app.staticTexts[
            "backend-signed-event-count"
        ]
        scrollDown(app, until: relaunchedSignedEventCount)
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedSignedEventCount,
                equalTo: "\(revokedSignedEventCount)",
                timeout: 10
            ),
            "重启不得重复记录退款撤销签名事件"
        )
        XCTAssertTrue(
            waitForLabel(
                of: app.staticTexts["backend-business-delivery-count"],
                equalTo: "\(revokedBusinessDeliveryCount)",
                timeout: 10
            ),
            "重启不得重复交付退款撤销业务状态"
        )
    }

    /// 验证超过前台等待窗口后才抵达的退款撤销，在后续冷启动中仍保持一致。
    ///
    /// 该用例不再次发起退款，只读取已经完成退款的 Sandbox 账号状态，并验证
    /// 撤销权益、可靠交付和幂等计数在两次冷启动之间不会倒退或重复。
    @MainActor
    func testDelayedYearlyRefundRevocationSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let signedEventCount = app.staticTexts["backend-signed-event-count"]
        let businessDeliveryCount = app.staticTexts["backend-business-delivery-count"]
        let revokedSignedEventCount = try integerLabel(
            of: signedEventCount,
            timeout: 10,
            failureMessage: "必须能读取退款撤销后的共享签名事件计数"
        )
        let revokedBusinessDeliveryCount = try integerLabel(
            of: businessDeliveryCount,
            timeout: 10,
            failureMessage: "必须能读取退款撤销后的业务交付计数"
        )

        try assertDelayedYearlyRefundRevocationState(in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))
        try assertDelayedYearlyRefundRevocationState(in: app)

        let relaunchedSignedEventCount = app.staticTexts[
            "backend-signed-event-count"
        ]
        scrollDown(app, until: relaunchedSignedEventCount)
        XCTAssertTrue(
            waitForLabel(
                of: relaunchedSignedEventCount,
                equalTo: "\(revokedSignedEventCount)",
                timeout: 10
            ),
            "冷启动不得重复记录延迟到达的退款撤销签名事件"
        )
        XCTAssertTrue(
            waitForLabel(
                of: app.staticTexts["backend-business-delivery-count"],
                equalTo: "\(revokedBusinessDeliveryCount)",
                timeout: 10
            ),
            "冷启动不得重复交付延迟到达的退款撤销业务状态"
        )
    }

    /// 测量示例程序的启动性能。
    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// 向列表顶部方向滚动，直到 SwiftUI 创建目标可访问性元素。
    @MainActor
    private func scrollDown(
        _ app: XCUIApplication,
        until element: XCUIElement,
        maximumAttempts: Int = 10
    ) {
        var remainingAttempts = maximumAttempts
        while !element.exists, remainingAttempts > 0 {
            app.swipeDown()
            remainingAttempts -= 1
        }
    }

    /// 验证专用恢复账号已持有永久解锁权益。
    ///
    /// 该检查在恢复前后各执行一次：第一次只验证账号前置，第二次验证恢复
    /// 返回后快照仍然收敛到同一既有权益。
    @MainActor
    private func assertRestorableLifetimeEntitlement(in app: XCUIApplication) {
        let lifetime = app.staticTexts["entitlement-paymentkit.demo.lifetime"]
        scroll(app, until: lifetime, maximumAttempts: 6)
        XCTAssertTrue(
            lifetime.waitForExistence(timeout: 10),
            "测试前置不满足：Sandbox 账号必须事先购买永久解锁"
        )
    }

    /// 验证月订阅权益、首购归因与自动续订状态已从真实 StoreKit 快照收敛。
    @MainActor
    private func assertMonthlyIntroductoryEntitlement(in app: XCUIApplication) {
        let monthlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyEntitlement, maximumAttempts: 6)
        XCTAssertTrue(
            monthlyEntitlement.waitForExistence(timeout: 120),
            "Sandbox 免费试用购买返回后，月订阅权益应自动出现"
        )

        let appliedOffer = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "实际优惠：首购优惠",
                "免费试用"
            )
        ).firstMatch
        XCTAssertTrue(
            appliedOffer.waitForExistence(timeout: 30),
            "真实 Sandbox 交易必须保留首购优惠与免费试用归因"
        )

        let monthlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyState, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: monthlyState,
                equalTo: "有效",
                timeout: 30
            ),
            "月订阅免费试用当前生命周期必须为有效"
        )

        let autoRenewStatus = app.staticTexts[
            "auto-renew-status-paymentkit.demo.monthly"
        ]
        XCTAssertTrue(
            waitForLabel(
                of: autoRenewStatus,
                equalTo: "将自动续订",
                timeout: 30
            ),
            "月订阅免费试用成交后必须显示将自动续订"
        )
    }

    /// 验证月订阅关闭自动续订后仍有效，或已自然到期并移除当前权益。
    @MainActor
    private func assertMonthlyAutoRenewOffState(in app: XCUIApplication) -> String {
        let monthlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyState, maximumAttempts: 8)
        XCTAssertTrue(
            monthlyState.waitForExistence(timeout: 120),
            "关闭自动续订后，StoreKit 必须保留月订阅生命周期状态"
        )

        let state = monthlyState.label
        XCTAssertTrue(
            state == "有效" || state == "已过期",
            "关闭自动续订后的月订阅状态必须是有效或已过期，实际为 \(state)"
        )

        let monthlyRenewalStatus = app.staticTexts[
            "auto-renew-status-paymentkit.demo.monthly"
        ]
        XCTAssertTrue(
            waitForLabel(
                of: monthlyRenewalStatus,
                equalTo: "不会自动续订",
                timeout: 120
            ),
            "StoreKit 快照必须显示月订阅不会自动续订"
        )

        let monthlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.monthly"
        ]
        scrollDown(app, until: monthlyEntitlement, maximumAttempts: 6)
        if state == "有效" {
            XCTAssertTrue(
                monthlyEntitlement.waitForExistence(timeout: 30),
                "月订阅仍有效时必须保留当前权益"
            )
        } else {
            XCTAssertFalse(
                monthlyEntitlement.exists,
                "月订阅已过期后不得继续保留当前权益"
            )
            XCTAssertTrue(
                app.staticTexts["运行时当前权益：无"].waitForExistence(
                    timeout: 30
                ),
                "月订阅已过期后 StoreKit 当前权益集合应为空"
            )
        }
        scroll(app, until: monthlyState, maximumAttempts: 8)
        XCTAssertTrue(
            monthlyState.exists,
            "生命周期断言结束后必须重新定位到同一月订阅状态"
        )
        return state
    }

    /// 验证年订阅当前权益来自月付承诺交易，而非预付交易或普通年订阅。
    @MainActor
    private func assertYearlyMonthlyCommitmentEntitlement(in app: XCUIApplication) {
        let yearlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyEntitlement, maximumAttempts: 6)
        XCTAssertTrue(
            yearlyEntitlement.waitForExistence(timeout: 120),
            "Sandbox 月付承诺购买返回后，年订阅权益应自动出现"
        )

        let billingPlan = app.staticTexts[
            "entitlement-billing-plan-paymentkit.demo.yearly"
        ]
        scroll(app, until: billingPlan, maximumAttempts: 3)
        XCTAssertTrue(
            waitForLabel(
                of: billingPlan,
                equalTo: "账单计划：月付 · 承诺 12 个月",
                timeout: 30
            ),
            "真实 Sandbox 交易必须保留月付承诺账单计划"
        )

        let commitmentProgress = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "承诺进度：第 ")
        ).firstMatch
        XCTAssertTrue(
            commitmentProgress.waitForExistence(timeout: 30),
            "真实 Sandbox 交易必须返回当前期数和总承诺期数"
        )
        XCTAssertTrue(
            commitmentProgress.label.hasSuffix("/12 期"),
            "真实 Sandbox 月付承诺交易的总期数必须为 12"
        )
    }

    /// 验证当前年订阅权益的真实付款方式，并返回稳定展示文本。
    @MainActor
    private func assertYearlyRefundTargetBillingPlan(
        in app: XCUIApplication
    ) throws -> String {
        let yearlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyEntitlement, maximumAttempts: 8)
        XCTAssertTrue(
            yearlyEntitlement.waitForExistence(timeout: 10),
            "测试前置不满足：退款前必须持有有效年订阅权益"
        )

        let billingPlan = app.staticTexts[
            "entitlement-billing-plan-paymentkit.demo.yearly"
        ]
        scroll(app, until: billingPlan, maximumAttempts: 3)
        XCTAssertTrue(
            billingPlan.waitForExistence(timeout: 10),
            "退款前必须能识别当前年订阅的付款方式"
        )

        let label = billingPlan.label
        XCTAssertTrue(
            ["账单计划：预付", "账单计划：月付 · 承诺 12 个月"].contains(label),
            "年订阅退款目标必须明确区分预付或月付承诺，实际为 \(label)"
        )

        if label == "账单计划：月付 · 承诺 12 个月" {
            let commitmentProgress = app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "承诺进度：第 ")
            ).firstMatch
            XCTAssertTrue(
                commitmentProgress.waitForExistence(timeout: 10),
                "月付承诺退款前必须能读取当前承诺进度"
            )
            XCTAssertTrue(
                commitmentProgress.label.hasSuffix("/12 期"),
                "月付承诺退款目标的总期数必须为 12"
            )
        }

        return label
    }

    /// 验证取消下一轮承诺不会把当前剩余月付分期误报为取消。
    @MainActor
    private func assertYearlyMonthlyCommitmentCancellationState(
        in app: XCUIApplication
    ) {
        let commitmentStatus = app.staticTexts[
            "commitment-renewal-status-paymentkit.demo.yearly"
        ]
        scroll(app, until: commitmentStatus)
        XCTAssertTrue(
            waitForLabel(
                of: commitmentStatus,
                equalTo: "下一承诺：已取消",
                timeout: 30
            ),
            "系统订阅管理返回后，下一轮 12 个月承诺必须自动刷新为已取消"
        )

        let periodStatus = app.staticTexts[
            "auto-renew-status-paymentkit.demo.yearly"
        ]
        XCTAssertTrue(periodStatus.waitForExistence(timeout: 10))
        XCTAssertTrue(
            periodStatus.label.contains("继续按月付款")
                || periodStatus.label == "当前承诺：全部分期已完成",
            "取消下一承诺后，当前剩余分期仍应继续，不能误报为全部取消"
        )

        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scrollDown(app, until: pendingTransactionsCount)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "取消下一承诺后不应遗留等待交付或 finish 的交易"
        )
    }

    /// 验证取消下一承诺后的最终到期状态不会保留权益或未完成交易。
    @MainActor
    private func assertExpiredYearlyMonthlyCommitmentState(
        in app: XCUIApplication
    ) {
        let yearlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyState)
        XCTAssertTrue(
            waitForLabel(of: yearlyState, equalTo: "已过期", timeout: 30),
            "当前承诺完成后，年订阅状态必须保持为已过期"
        )

        let commitmentStatus = app.staticTexts[
            "commitment-renewal-status-paymentkit.demo.yearly"
        ]
        if commitmentStatus.exists {
            XCTAssertEqual(
                commitmentStatus.label,
                "下一承诺：已取消",
                "StoreKit 仍返回承诺结构时，下一承诺必须保持已取消"
            )
        } else {
            let renewalStatus = app.staticTexts[
                "auto-renew-status-paymentkit.demo.yearly"
            ]
            XCTAssertTrue(
                waitForLabel(
                    of: renewalStatus,
                    equalTo: "不会自动续订",
                    timeout: 30
                ),
                "StoreKit 到期后移除承诺结构时，仍必须明确展示不会自动续订"
            )
        }

        let yearlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.yearly"
        ]
        scrollDown(app, until: yearlyEntitlement, maximumAttempts: 4)
        XCTAssertFalse(
            yearlyEntitlement.exists,
            "月付承诺到期后不得继续保留年订阅当前权益"
        )

        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "全部分期处理完成后不应遗留等待交付或 finish 的交易"
        )
    }

    /// 验证预付年订阅关闭续订后的生命周期与待处理交易状态。
    @MainActor
    private func assertYearlyUpFrontCancellationState(
        in app: XCUIApplication
    ) -> String {
        XCTAssertTrue(app.staticTexts["status-message"].waitForExistence(timeout: 10))

        let yearlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyState)
        XCTAssertTrue(
            yearlyState.waitForExistence(timeout: 10),
            "关闭自动续订后必须保留年订阅生命周期状态"
        )
        let lifecycleState = yearlyState.label
        XCTAssertTrue(
            ["有效", "已过期"].contains(lifecycleState),
            "关闭自动续订后的年订阅必须处于有效或已过期状态"
        )

        let yearlyStatuses = app.staticTexts.matching(
            identifier: "auto-renew-status-paymentkit.demo.yearly"
        )
        let yearlyRenewalStatus = yearlyStatuses.firstMatch
        scroll(app, until: yearlyRenewalStatus)
        XCTAssertEqual(
            yearlyStatuses.count, 1,
            "必须恰好存在一个年订阅自动续订状态元素"
        )
        XCTAssertTrue(
            waitForLabel(
                of: yearlyRenewalStatus,
                equalTo: "不会自动续订",
                timeout: 30
            ),
            "关闭自动续订的状态必须在启动后自动恢复"
        )

        if lifecycleState == "有效" {
            let yearlyEntitlement = app.staticTexts[
                "entitlement-paymentkit.demo.yearly"
            ]
            scrollDown(app, until: yearlyEntitlement)
            XCTAssertTrue(
                yearlyEntitlement.waitForExistence(timeout: 10),
                "订阅仍有效时，预付年订阅必须保有当前权益"
            )

            let billingPlan = app.staticTexts[
                "entitlement-billing-plan-paymentkit.demo.yearly"
            ]
            scroll(app, until: billingPlan, maximumAttempts: 4)
            XCTAssertTrue(
                waitForLabel(
                    of: billingPlan,
                    equalTo: "账单计划：预付",
                    timeout: 10
                ),
                "有效年订阅的当前权益必须保持为预付账单计划"
            )
        }

        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scrollDown(app, until: pendingTransactionsCount)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "重启协调后不应遗留等待交付或 finish 的交易"
        )
        return lifecycleState
    }

    /// 验证延迟到达的年订阅退款撤销已完全收敛。
    @MainActor
    private func assertDelayedYearlyRefundRevocationState(
        in app: XCUIApplication
    ) throws {
        let yearlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.yearly"
        ]
        scroll(app, until: yearlyState)
        XCTAssertTrue(
            waitForLabel(of: yearlyState, equalTo: "已撤销", timeout: 30),
            "延迟退款事件到达后，年订阅状态必须为已撤销"
        )

        let yearlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.yearly"
        ]
        scrollDown(app, until: yearlyEntitlement)
        XCTAssertFalse(
            yearlyEntitlement.exists,
            "退款撤销后不得恢复年订阅权益"
        )

        let pendingTransactionsCount = app.staticTexts["pending-transactions-count"]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "延迟退款撤销完成后不得遗留等待交付或 finish 的交易"
        )
    }

    /// 验证 Sandbox 账单恢复后的月订阅状态已完全收敛。
    @MainActor
    private func assertSandboxMonthlyBillingRecoveryState(
        in app: XCUIApplication
    ) throws {
        let monthlyState = app.staticTexts[
            "subscription-state-paymentkit.demo.monthly"
        ]
        scroll(app, until: monthlyState, maximumAttempts: 8)
        XCTAssertTrue(
            waitForLabel(of: monthlyState, equalTo: "有效", timeout: 60),
            "重新允许 Sandbox 续订后，月订阅必须恢复为有效"
        )

        let monthlyEntitlement = app.staticTexts[
            "entitlement-paymentkit.demo.monthly"
        ]
        scrollDown(app, until: monthlyEntitlement, maximumAttempts: 6)
        XCTAssertTrue(
            monthlyEntitlement.waitForExistence(timeout: 30),
            "账单恢复后必须重新获得月订阅当前权益"
        )

        let renewalStatus = app.staticTexts[
            "auto-renew-status-paymentkit.demo.monthly"
        ]
        scroll(app, until: renewalStatus, maximumAttempts: 4)
        XCTAssertTrue(
            waitForLabel(
                of: renewalStatus,
                equalTo: "将自动续订",
                timeout: 30
            ),
            "账单恢复后月订阅必须继续自动续订"
        )

        let pendingTransactionsCount = app.staticTexts[
            "pending-transactions-count"
        ]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 8)
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "账单恢复交易必须完成后台交付与 StoreKit finish"
        )
    }

    /// 仅验证可靠交付队列；用于快速冷启动探针，避免跨过下一续订边界。
    @MainActor
    private func assertSandboxPendingTransactionsAreZero(
        in app: XCUIApplication
    ) {
        let pendingTransactionsCount = app.staticTexts[
            "pending-transactions-count"
        ]
        scroll(app, until: pendingTransactionsCount, maximumAttempts: 8)
        XCTAssertTrue(
            pendingTransactionsCount.waitForExistence(timeout: 10),
            "必须能访问待处理交易状态区域"
        )
        XCTAssertTrue(
            waitForLabel(
                of: pendingTransactionsCount,
                equalTo: "待处理交易（0）",
                timeout: 30
            ),
            "启动重放后交易必须完成后台交付与 StoreKit finish"
        )
    }

    /// 等待 Apple 系统界面覆盖应用并返回。
    ///
    /// XCTest 不操作购买、认证或订阅管理等财务界面；测试人员完成系统
    /// 交互后，原按钮才会重新变为可点击状态。
    @MainActor
    private func waitForSystemPresentationRoundTrip(
        observedElement: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let presented = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == false"),
            object: observedElement
        )
        guard XCTWaiter.wait(for: [presented], timeout: 10) == .completed else {
            return false
        }

        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: observedElement
        )
        return XCTWaiter.wait(for: [returned], timeout: timeout) == .completed
    }

    /// 等待 iOS 26 的系统 Sandbox 购买页出现并由测试人员完成。
    ///
    /// 购买页属于 SpringBoard，测试只观察“订阅”按钮的出现和消失，绝不代替
    /// 测试人员操作财务界面。
    @MainActor
    private func waitForSandboxPurchasePresentationRoundTrip(
        application app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let subscribeButton = springboard.buttons["订阅"]
        guard subscribeButton.waitForExistence(timeout: 30) else {
            return false
        }

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: subscribeButton
        )
        guard XCTWaiter.wait(for: [dismissed], timeout: timeout) == .completed else {
            return false
        }
        return app.wait(for: .runningForeground, timeout: 30)
    }

    /// 等待一次异步用户操作从禁用主按钮到重新启用。
    ///
    /// 真机系统财务界面可能显示在 Mac 的设备协同窗口中，此时不会遮挡 iPhone 上的
    /// 可访问性树；按钮的 `isEnabled` 生命周期仍能稳定反映操作是否在途。
    @MainActor
    private func waitForOperationRoundTrip(
        observedElement: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let started = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == false"),
            object: observedElement
        )
        guard XCTWaiter.wait(for: [started], timeout: 10) == .completed else {
            return false
        }

        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: observedElement
        )
        return XCTWaiter.wait(for: [completed], timeout: timeout) == .completed
    }

    /// 逐步滚动长列表，直到 SwiftUI 创建目标可访问性元素。
    @MainActor
    private func scroll(
        _ app: XCUIApplication,
        until element: XCUIElement,
        maximumAttempts: Int = 10
    ) {
        var remainingAttempts = maximumAttempts
        while !element.exists, remainingAttempts > 0 {
            app.swipeUp()
            remainingAttempts -= 1
        }
    }

    /// 逐步滚动长列表，直到目标元素进入可点击区域。
    @MainActor
    private func scroll(
        _ app: XCUIApplication,
        untilHittable element: XCUIElement,
        maximumAttempts: Int = 4
    ) {
        var remainingAttempts = maximumAttempts
        while !element.isHittable, remainingAttempts > 0 {
            app.swipeUp()
            remainingAttempts -= 1
        }
    }

    /// 在有限时间内等待可访问性文本变为指定值。
    @MainActor
    private func waitForLabel(
        of element: XCUIElement,
        equalTo expectedLabel: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expectedLabel),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// 在有限时间内等待可访问性文本出现指定前缀。
    @MainActor
    private func waitForLabel(
        of element: XCUIElement,
        beginningWith expectedPrefix: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", expectedPrefix),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// 读取一个以十进制整数展示的可访问性文本。
    @MainActor
    private func integerLabel(
        of element: XCUIElement,
        timeout: TimeInterval,
        failureMessage: String
    ) throws -> Int {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), failureMessage)
        return try XCTUnwrap(Int(element.label), failureMessage)
    }

    /// 等待整数可访问性值达到下限，并返回最终值。
    @MainActor
    private func waitForIntegerLabel(
        of element: XCUIElement,
        atLeast minimumValue: Int,
        timeout: TimeInterval
    ) -> Int? {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement,
                      let value = Int(element.label) else {
                    return false
                }
                return value >= minimumValue
            },
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            return nil
        }
        return Int(element.label)
    }

}
