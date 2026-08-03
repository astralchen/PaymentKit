import PaymentKit
import SwiftUI

/// 自动续期订阅的续订状态展示。
///
/// 月付承诺包含两个不同层级的续订状态：当前承诺内的下一笔月付，以及当前
/// 承诺结束后是否开始新的承诺。此类型将两者分开，避免把取消下一承诺误写成
/// 当前剩余分期也已取消。
nonisolated struct SubscriptionRenewalPresentation: Equatable {
    /// 当前订阅周期或当前承诺的付款状态。
    let periodStatus: String

    /// 当前承诺结束后的续订状态；普通订阅为 `nil`。
    let commitmentStatus: String?

    /// 当前承诺的分期进度；普通订阅或 StoreKit 未返回进度时为 `nil`。
    let progressStatus: String?

    /// 当前订阅周期在界面中使用的名称。
    let nextPeriodPrefix: String

    /// 创建续订状态展示。
    init(
        renewalInfo: PaymentRenewalInfo,
        transactionCommitment: PaymentTransactionCommitment?
    ) {
        if let commitment = renewalInfo.commitment {
            if let transactionCommitment {
                // 交易进度是当前承诺剩余分期的事实来源，避免续订信息在账单
                // 边界传播时短暂为 false，误写成当前承诺已停止付款。
                let currentPeriod = transactionCommitment.billingPeriodNumber
                let totalPeriods = transactionCommitment.totalBillingPeriods
                let remainingPeriods = currentPeriod < totalPeriods
                    ? totalPeriods - currentPeriod
                    : 0
                periodStatus = remainingPeriods > 0
                    ? "当前承诺：剩余 \(remainingPeriods) 期继续按月付款"
                    : "当前承诺：全部分期已完成"
                progressStatus = "承诺进度：第 \(currentPeriod)/\(totalPeriods) 期"
            } else {
                // 旧持久化数据可能没有承诺进度；此时只陈述 StoreKit 返回的
                // 下一账单期安排，不推算剩余期数。
                periodStatus = renewalInfo.willAutoRenew
                    ? "当前承诺：下一分期将继续"
                    : "当前承诺：分期状态待 StoreKit 更新"
                progressStatus = nil
            }
            commitmentStatus = commitment.willAutoRenew
                ? "下一承诺：将自动续期"
                : "下一承诺：已取消"
            nextPeriodPrefix = "下期分期"
        } else {
            periodStatus = renewalInfo.willAutoRenew
                ? "将自动续订"
                : "不会自动续订"
            commitmentStatus = nil
            progressStatus = nil
            nextPeriodPrefix = "下期续订"
        }
    }
}

/// 展示 PaymentKit 全部中立能力的验证界面。
struct ContentView: View {
    @ObservedObject var model: PaymentKitExampleModel

    var body: some View {
        NavigationView {
            List {
                statusSection
                backendSection
                productsSection
                purchaseIntentsSection
                storeMessagesSection
                actionsSection
                entitlementsSection
                unfinishedSection
                subscriptionsSection
                backendRecordsSection
                eventsSection
            }
            .navigationTitle("PaymentKit")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("refresh-button")
                }
            }
            .overlay {
                if model.isBusy {
                    ProgressView()
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("正在处理")
                }
            }

            Text("选择商品以查看内购状态")
                .foregroundStyle(.secondary)
        }
        .task {
            await model.startIfNeeded()
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var statusSection: some View {
        Section("运行状态") {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    model.snapshot.canMakePayments ? "允许购买" : "购买受限",
                    systemImage: model.snapshot.canMakePayments
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.snapshot.canMakePayments ? .green : .orange)
                Spacer()
                Text("iOS 15+ · macOS 13+")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(model.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("status-message")

            if ProcessInfo.processInfo.arguments.contains(
                "-PaymentKitStoreKitRuntimeProbe"
            ) {
                let yearlyProduct = model.snapshot.products.first {
                    $0.id == "paymentkit.demo.yearly"
                }
                let entitlementIDs = model.snapshot.currentEntitlements
                    .map(\.productID)
                    .sorted()
                    .joined(separator: ",")
                let yearlyStatus = model.snapshot.subscriptionStatuses.first {
                    $0.transaction.productID == "paymentkit.demo.yearly"
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "运行时年订阅价格：\(yearlyProduct?.displayPrice ?? "加载中")"
                    )
                    Text(
                        "运行时当前权益：\(entitlementIDs.isEmpty ? "无" : entitlementIDs)"
                    )
                    Text(
                        "运行时年订阅状态：\(yearlyStatus?.state.displayName ?? "无")"
                    )
                }
                .font(.caption.monospaced())
                .accessibilityIdentifier("storekit-runtime-probe")
            }

            if !model.snapshot.unavailableProductIDs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("未返回的商品 ID")
                        .font(.caption.weight(.semibold))
                    ForEach(model.snapshot.unavailableProductIDs, id: \.self) {
                        Text($0).font(.caption.monospaced())
                    }
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private var backendSection: some View {
        Section("模拟后台") {
            Toggle(
                "后台联网",
                isOn: Binding(
                    get: { model.backendSnapshot.isOnline },
                    set: { model.setBackendOnline($0) }
                )
            )
            .accessibilityIdentifier("backend-online-toggle")

            Picker(
                "故障注入",
                selection: Binding(
                    get: { model.backendSnapshot.faultMode },
                    set: { model.setBackendFaultMode($0) }
                )
            ) {
                ForEach(MockBackendFaultMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            LabeledValue(
                title: "模拟延迟",
                value: "\(model.backendSnapshot.latencyMilliseconds) ms",
                valueAccessibilityIdentifier: "backend-latency"
            )
            LabeledValue(
                title: "共享签名事件",
                value: "\(model.backendSnapshot.signedEventCount)",
                valueAccessibilityIdentifier: "backend-signed-event-count"
            )
            LabeledValue(
                title: "业务交付",
                value: "\(model.backendSnapshot.businessDeliveryCount)",
                valueAccessibilityIdentifier: "backend-business-delivery-count"
            )

            #if DEBUG && os(iOS)
            Button {
                model.armConcurrentOutboxProbe()
            } label: {
                Label(
                    model.isConcurrentOutboxProbeArmed
                        ? "主 App 后台并发探针已准备"
                        : "准备主 App/扩展并发重试",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(model.isConcurrentOutboxProbeArmed)
            .accessibilityIdentifier("arm-concurrent-outbox-probe")

            Text("仅 Debug：准备后在 25 秒内从分享扩展重试；主 App 会在扩展提交后并发重放同一 outbox。")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif

            Text("主 App 与扩展共用 SQLite 幂等账本；后台不保存 JWS，也不授予会员、余额或其他业务权益。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var productsSection: some View {
        Section("商品（\(model.snapshot.products.count)）") {
            if model.snapshot.products.isEmpty {
                Text("尚未加载商品。请确认共享 Scheme 已启用 PaymentKit.storekit。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.products) { product in
                    ProductRow(
                        product: product,
                        isDisabled: model.isBusy,
                        selectedBillingPlan: model.selectedBillingPlan(for: product),
                        selectedOffer: model.selectedOffer(for: product),
                        availableOffers: model.availableOffers(for: product),
                        sandboxOfferCodeCatalogPresentation: product.id
                            == ExampleProducts.yearly
                            ? SandboxOfferCodeCatalogPresentation(
                                status: model.sandboxOfferCodeCatalogStatus,
                                validCodeCount: model.sandboxOfferCodes.count,
                                invalidLineCount: model.sandboxOfferCodeInvalidLineCount,
                                duplicateLineCount: model.sandboxOfferCodeDuplicateLineCount
                            )
                            : nil,
                        promotionalAuthorizationJWS: $model.promotionalAuthorizationJWS,
                        selectBillingPlan: {
                            model.selectBillingPlan($0, for: product.id)
                        },
                        selectOffer: {
                            model.selectOffer($0, for: product.id)
                        }
                    ) {
                        Task { await model.performPrimaryAction(for: product) }
                    }
                }
            }

            Toggle("下一笔模拟 Ask to Buy", isOn: $model.simulatesAskToBuy)
                .accessibilityIdentifier("ask-to-buy-toggle")
        }
    }

    private var purchaseIntentsSection: some View {
        Section("App Store 购买意图（\(model.purchaseIntents.count)）") {
            if model.purchaseIntents.isEmpty {
                Text("没有等待界面决定的普通购买或回归优惠")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.purchaseIntents) { intent in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(intent.productID)
                            .font(.callout.monospaced())
                        if let offer = intent.offer {
                            Text("系统优惠：\(offer.displayDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("接受") {
                                Task { await model.accept(intent) }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("放弃", role: .cancel) {
                                Task { await model.abandon(intent) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var storeMessagesSection: some View {
        Section("StoreKit 系统消息（\(model.storeMessages.count)）") {
            if !model.interceptsStoreMessages {
                Text("默认由 StoreKit 自动展示；只有点击接管后框架才开始消费 Message.messages。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("接管系统消息展示时机") {
                    model.enableStoreMessageInterception()
                }
            } else if model.storeMessages.isEmpty {
                Text("已接管，当前没有待展示消息")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.storeMessages) { message in
                    HStack {
                        Text(message.reason.displayName)
                        Spacer()
                        Button("系统展示") {
                            Task { await model.display(message) }
                        }
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section("用户操作") {
            Button {
                Task { await model.redeemOfferCode() }
            } label: {
                Label("兑换优惠代码", systemImage: "ticket")
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("redeem-offer-code-button")

            Button {
                Task { await model.restorePurchases() }
            } label: {
                Label("恢复购买", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("restore-button")

            Button {
                Task { await model.retryUnfinishedTransactions() }
            } label: {
                Label("重试 unfinished 交易", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("retry-button")

#if os(iOS)
            Button {
                Task { await model.showManageSubscriptions() }
            } label: {
                Label("管理订阅", systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("manage-subscriptions-button")
#endif
        }
    }

    private var entitlementsSection: some View {
        Section("当前权益（\(model.snapshot.currentEntitlements.count)）") {
            if model.snapshot.currentEntitlements.isEmpty {
                Text("没有已验证的当前权益")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.currentEntitlements) { transaction in
                    TransactionRow(transaction: transaction) {
                        Task { await model.requestRefund(for: transaction) }
                    }
                    .disabled(model.isBusy)
                }
            }

            Text("PaymentKit 不计算消耗品余额，也不推断非续期订阅的业务有效期。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unfinishedSection: some View {
        Section {
            if model.snapshot.pendingTransactions.isEmpty {
                Text("没有等待交付或 finish 的交易")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.pendingTransactions) { pending in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pending.transaction.productID)
                            .font(.callout.monospaced())
                        Text(
                            pending.state == .awaitingDelivery
                                ? "交易 …\(String(pending.transaction.id).suffix(6)) · 等待后台交付"
                                : "交易 …\(String(pending.transaction.id).suffix(6)) · 已交付，等待 finish"
                        )
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("待处理交易（\(model.snapshot.pendingTransactions.count)）")
                .accessibilityIdentifier("pending-transactions-count")
        }
    }

    private var subscriptionsSection: some View {
        Section("订阅状态（\(model.snapshot.subscriptionStatuses.count)）") {
            if model.snapshot.subscriptionStatuses.isEmpty {
                Text("没有自动续期订阅状态")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.subscriptionStatuses) { status in
                    let presentation = SubscriptionRenewalPresentation(
                        renewalInfo: status.renewalInfo,
                        transactionCommitment: status.transaction.commitment
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(status.renewalInfo.currentProductID)
                                .font(.callout.monospaced())
                            Spacer()
                            Text(status.state.displayName)
                                .font(.caption.weight(.semibold))
                                .accessibilityIdentifier(
                                    "subscription-state-\(status.renewalInfo.currentProductID)"
                                )
                        }
                        Text(presentation.periodStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "auto-renew-status-\(status.renewalInfo.currentProductID)"
                            )
                        if let commitmentStatus = presentation.commitmentStatus {
                            Text(commitmentStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(
                                    "commitment-renewal-status-\(status.renewalInfo.currentProductID)"
                                )
                        }
                        if let progressStatus = presentation.progressStatus {
                            // 月付承诺显示交易记录的实际期数；不使用可能处于
                            // 传播边界的续订布尔值推断当前承诺是否还有分期。
                            Text(progressStatus)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            // 普通订阅是否续订以 willAutoRenew 为准，避免状态
                            // 传播期间的旧偏好造成误导。
                            if status.renewalInfo.willAutoRenew,
                               let preference = status.renewalInfo.autoRenewPreference {
                                Text(
                                    preference == status.renewalInfo.currentProductID
                                        ? "\(presentation.nextPeriodPrefix)：\(preference)"
                                        : "下期切换：\(preference)"
                                )
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            } else {
                                Text("\(presentation.nextPeriodPrefix)：无")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let offer = status.transaction.appliedOffer {
                            Text("当前交易优惠：\(offer.displayName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let offer = status.renewalInfo.appliedOffer {
                            Text("续订信息优惠：\(offer.displayName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var backendRecordsSection: some View {
        Section("本进程后台记录（最近 50 条）") {
            if model.backendSnapshot.records.isEmpty {
                Text("尚未接收交易 JWS")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.backendSnapshot.records) { record in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.productID)
                                .font(.caption.monospaced())
                            Text("交易 …\(record.transactionSuffix)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.result.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(record.result.color)
                    }
                }
            }
        }
    }

    private var eventsSection: some View {
        Section("PaymentEvent（仅用于界面与诊断）") {
            if model.events.isEmpty {
                Text("尚未收到事件")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                    Text(event)
                        .font(.caption)
                }
            }
        }
    }
}

/// 将 Sandbox 优惠代码目录状态转换为不含敏感值的界面文案。
nonisolated struct SandboxOfferCodeCatalogPresentation: Equatable, Sendable {
    let statusText: String
    let issueText: String?
    let hasValidCodes: Bool

    init(
        status: SandboxOfferCodeCatalogStatus,
        validCodeCount: Int,
        invalidLineCount: Int,
        duplicateLineCount: Int
    ) {
        hasValidCodes = validCodeCount > 0
        switch status {
        case .loaded where validCodeCount > 0:
            statusText = "Sandbox 优惠代码：\(validCodeCount) 条，仅用于测试"
        case .loaded, .missing, .empty:
            statusText = "未配置 Sandbox 优惠代码"
        case .unreadable, .invalidEncoding, .fileTooLarge, .tooManyRecords:
            statusText = "Sandbox 优惠代码配置不可用"
        }

        var issues: [String] = []
        if invalidLineCount > 0 {
            issues.append("无效行：\(invalidLineCount) 条")
        }
        if duplicateLineCount > 0 {
            issues.append("重复行：\(duplicateLineCount) 条")
        }
        issueText = issues.isEmpty ? nil : issues.joined(separator: " · ")
    }
}

/// 展示一组简短的名称和值。
private struct LabeledValue: View {
    let title: String
    let value: String
    let valueAccessibilityIdentifier: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier(valueAccessibilityIdentifier)
        }
    }
}

/// 把可选择优惠与只读占位分开，避免“未配置”成为购买状态。
struct SandboxOfferCodeMenuPresentation: Equatable {
    let selectableOffers: [ExampleOfferChoice]
    let unselectablePlaceholderText: String?

    init(
        selectableOffers: [ExampleOfferChoice],
        hasValidSandboxOfferCodes: Bool
    ) {
        self.selectableOffers = selectableOffers
        unselectablePlaceholderText = hasValidSandboxOfferCodes
            ? nil
            : "未配置 Sandbox 优惠代码"
    }
}

/// 展示一个可购买商品。
private struct ProductRow: View {
    let product: PaymentProduct
    let isDisabled: Bool
    let selectedBillingPlan: PaymentBillingPlan?
    let selectedOffer: ExampleOfferChoice
    let availableOffers: [ExampleOfferChoice]
    let sandboxOfferCodeCatalogPresentation: SandboxOfferCodeCatalogPresentation?
    @Binding var promotionalAuthorizationJWS: String
    let selectBillingPlan: (PaymentBillingPlan) -> Void
    let selectOffer: (ExampleOfferChoice) -> Void
    let primaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.displayName)
                        .font(.headline)
                    Text(product.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.type.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Text(product.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let subscription = product.subscription {
                if subscription.pricingTerms.count > 1,
                   let selectedBillingPlan {
                    Picker(
                        "定价方案",
                        selection: Binding(
                            get: { selectedBillingPlan },
                            set: { value in
                                selectBillingPlan(value)
                            }
                        )
                    ) {
                        ForEach(subscription.pricingTerms, id: \.billingPlan) { terms in
                            Text(terms.billingPlan.displayName)
                                .tag(terms.billingPlan)
                                .accessibilityIdentifier(
                                    "billing-plan-\(product.id)-\(terms.billingPlan.accessibilityComponent)"
                                )
                        }
                    }
                    .pickerStyle(.segmented)
                }

                ForEach(subscription.pricingTerms, id: \.billingPlan) { terms in
                    if terms.billingPlan == selectedBillingPlan {
                        PricingTermsView(terms: terms)
                    }
                }

                Menu {
                    ForEach(offerMenuPresentation.selectableOffers) { choice in
                        Button(choice.displayName) {
                            selectOffer(choice)
                        }
                    }
                    if let placeholder =
                        offerMenuPresentation.unselectablePlaceholderText {
                        Divider()
                        Button(placeholder) {}
                            .disabled(true)
                            .accessibilityIdentifier(
                                "sandbox-offer-code-unconfigured-placeholder"
                            )
                    }
                } label: {
                    HStack {
                        Text("购买优惠")
                        Spacer()
                        Text(selectedOffer.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("purchase-offer-\(product.id)")

                if let sandboxOfferCodeCatalogPresentation {
                    Text(sandboxOfferCodeCatalogPresentation.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let issueText = sandboxOfferCodeCatalogPresentation.issueText {
                        Text(issueText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .promotional = selectedOffer {
                    SecureField(
                        "促销 compact JWS（仅保存在内存）",
                        text: $promotionalAuthorizationJWS
                    )
                    .textContentType(.oneTimeCode)
                    .font(.caption.monospaced())
                }

                if let selectedPricingTerms,
                   let offer = selectedPricingTerms.offers.first(
                       where: { $0.type == .introductory }
                   ) {
                    if subscription.isEligibleForIntroductoryOffer {
                        Text(
                            offer.introductoryDescription(
                                standardTerms: selectedPricingTerms
                            )
                        )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text("当前账户不符合该订阅组首购优惠资格")
                            .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                if let selectedPricingTerms {
                    Text(
                        "标准续订：\(selectedPricingTerms.billingDisplayPrice) / \(selectedPricingTerms.billingPeriod.displayName)"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(selectedPlanPromotionalOffers, id: \.stableID) { offer in
                    Text("促销：\(offer.displayDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(selectedPlanWinBackOffers, id: \.stableID) { offer in
                    Text("回归：\(offer.displayDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if let selectedPricingTerms {
                    Text(selectedPricingTerms.billingPeriod.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(purchaseButtonTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled)
                    .accessibilityIdentifier("purchase-\(product.id)")
            }
        }
        .padding(.vertical, 4)
    }

    private var purchaseButtonTitle: String {
        switch selectedOffer {
        case .introductory:
            guard
                product.subscription?.isEligibleForIntroductoryOffer == true,
                let offer = selectedPricingTerms?.offers.first(
                    where: { $0.type == .introductory }
                )
            else {
                return selectedPricingTerms?.billingDisplayPrice
                    ?? product.displayPrice
            }
            switch offer.paymentMode {
            case .freeTrial:
                return "免费试用"
            case .payAsYouGo, .payUpFront:
                return offer.displayPrice
            case .unknown:
                return selectedPricingTerms?.billingDisplayPrice
                    ?? product.displayPrice
            }
        case .promotional:
            return "使用促销优惠"
        case .winBack:
            return "使用回归优惠"
        case .sandboxOfferCode:
            return "复制并兑换优惠代码"
        case .standard:
            return selectedBillingPlan == .monthlyCommitment
                ? "确认 12 个月承诺"
                : product.displayPrice
        }
    }

    /// 返回当前账单计划对应的定价条款。
    ///
    /// 优惠文案和购买按钮只读取这里的优惠集合，避免跨账单计划混用。
    private var selectedPricingTerms: PaymentSubscriptionPricingTerms? {
        product.subscription?.pricingTerms.first {
            $0.billingPlan == selectedBillingPlan
        }
    }

    /// 返回仅属于当前账单计划的促销优惠。
    private var selectedPlanPromotionalOffers: [PaymentSubscriptionOffer] {
        selectedPricingTerms?.offers.filter { $0.type == .promotional } ?? []
    }

    /// 返回仅属于当前账单计划的回归优惠。
    private var selectedPlanWinBackOffers: [PaymentSubscriptionOffer] {
        selectedPricingTerms?.offers.filter { $0.type == .winBack } ?? []
    }

    private var offerMenuPresentation: SandboxOfferCodeMenuPresentation {
        SandboxOfferCodeMenuPresentation(
            selectableOffers: availableOffers,
            hasValidSandboxOfferCodes:
                sandboxOfferCodeCatalogPresentation?.hasValidCodes ?? true
        )
    }
}

/// 展示购买前必须明确告知用户的账单计划与总承诺。
private struct PricingTermsView: View {
    let terms: PaymentSubscriptionPricingTerms

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                "\(terms.billingDisplayPrice) / \(terms.billingPeriod.displayName)"
            )
            .font(.caption.weight(.semibold))
            if terms.billingPlan == .monthlyCommitment {
                Text(
                    "总承诺 \(terms.commitment.displayPrice) · \(terms.commitment.period.offerDuration(periodCount: 1))"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }
}

/// 展示一笔当前权益交易及退款入口。
private struct TransactionRow: View {
    let transaction: PaymentTransaction
    let requestRefund: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transaction.productID)
                .font(.callout.monospaced())
                .accessibilityIdentifier("entitlement-\(transaction.productID)")
            HStack {
                Text("交易 …\(String(transaction.id).suffix(6))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("申请退款", action: requestRefund)
                    .font(.caption)
                    .accessibilityIdentifier("refund-\(transaction.productID)")
            }
            if let offer = transaction.appliedOffer {
                Text("实际优惠：\(offer.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let billingPlan = transaction.billingPlan {
                Text("账单计划：\(billingPlan.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "entitlement-billing-plan-\(transaction.productID)"
                    )
            }
            if let commitment = transaction.commitment {
                Text(
                    "承诺进度：第 \(commitment.billingPeriodNumber)/\(commitment.totalBillingPeriods) 期"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private extension PaymentSubscriptionOffer {
    var stableID: String {
        "\(type.displayName)|\(id ?? "none")|\(displayPrice)|\(periodCount)"
    }

    var displayDescription: String {
        let duration = period.offerDuration(periodCount: periodCount)
        let identifier = id.map { " · \($0)" } ?? ""
        return "\(type.displayName) · \(paymentMode.displayName) · \(displayPrice) · \(duration)\(identifier)"
    }

    /// 创建包含优惠期和标准续订价格的中立展示文案。
    func introductoryDescription(
        standardTerms: PaymentSubscriptionPricingTerms
    ) -> String {
        let duration = period.offerDuration(periodCount: periodCount)
        let standardPrice = [
            standardTerms.billingDisplayPrice,
            standardTerms.billingPeriod.displayName,
        ].joined(separator: " / ")
        switch paymentMode {
        case .freeTrial:
            return "免费试用 \(duration)，之后按 \(standardPrice) 续订"
        case .payAsYouGo:
            return "首购 \(duration) 每期 \(displayPrice)，之后按 \(standardPrice) 续订"
        case .payUpFront:
            return "首购 \(duration) 预付 \(displayPrice)，之后按 \(standardPrice) 续订"
        case .unknown:
            return "首购优惠 \(displayPrice)，之后按 \(standardPrice) 续订"
        }
    }
}

private extension ExampleOfferChoice {
    var displayName: String {
        switch self {
        case .standard: "标准价格"
        case .introductory: "首购优惠"
        case .promotional(let offerID): "促销优惠 · \(offerID)"
        case .winBack(let offerID): "回归优惠 · \(offerID)"
        case .sandboxOfferCode(_, let displayName): displayName
        }
    }
}

private extension PaymentBillingPlan {
    /// 返回不依赖本地化文案的界面自动化标识片段。
    var accessibilityComponent: String {
        switch self {
        case .upFront:
            "up-front"
        case .monthlyCommitment:
            "monthly-commitment"
        case .unknown(let rawValue):
            "unknown-\(rawValue)"
        }
    }

    var displayName: String {
        switch self {
        case .upFront: "预付"
        case .monthlyCommitment: "月付 · 承诺 12 个月"
        case .unknown(let rawValue): "未知计划（\(rawValue)）"
        }
    }
}

private extension PaymentOfferType {
    var displayName: String {
        switch self {
        case .introductory: "首购优惠"
        case .promotional: "促销优惠"
        case .offerCode: "优惠代码"
        case .winBack: "回归用户优惠"
        case .unknown(let rawValue): "未知优惠（\(rawValue)）"
        }
    }
}

private extension PaymentSubscriptionOffer.PaymentMode {
    var displayName: String {
        switch self {
        case .payAsYouGo: "按期优惠"
        case .payUpFront: "预付优惠"
        case .freeTrial: "免费试用"
        case .unknown(let rawValue): "未知付款方式（\(rawValue)）"
        }
    }
}

private extension PaymentStoreMessageReason {
    var displayName: String {
        switch self {
        case .generic: "App Store 消息"
        case .priceIncreaseConsent: "价格上涨同意"
        case .billingIssue: "账单问题"
        case .winBack: "回归优惠"
        case .unknown(let rawValue): "未知消息（\(rawValue)）"
        }
    }
}

private extension PaymentAppliedOffer {
    var displayName: String {
        let typeName = switch type {
        case .introductory: "首购优惠"
        case .promotional: "促销优惠"
        case .offerCode: "优惠代码"
        case .winBack: "回归用户优惠"
        case .unknown(let rawValue): "未知优惠（\(rawValue)）"
        }
        let modeName: String? = switch paymentMode {
        case .payAsYouGo: "按期优惠"
        case .payUpFront: "预付优惠"
        case .freeTrial: "免费试用"
        case .unknown(let rawValue): "未知付款方式（\(rawValue)）"
        case nil: nil
        }
        let duration = period.map { $0.offerDuration(periodCount: 1) }
            ?? periodRawValue
        return [typeName, modeName, duration].compactMap { $0 }.joined(separator: " · ")
    }
}

private extension PaymentProductType {
    var displayName: String {
        switch self {
        case .consumable: "消耗型"
        case .nonConsumable: "非消耗型"
        case .nonRenewingSubscription: "非续期订阅"
        case .autoRenewableSubscription: "自动续期订阅"
        case .unknown(let value): "未知（\(value)）"
        }
    }
}

private extension PaymentSubscriptionPeriod {
    var displayName: String {
        let unitName = switch unit {
        case .day: "天"
        case .week: "周"
        case .month: "月"
        case .year: "年"
        case .unknown: "未知周期"
        }
        return "每 \(value) \(unitName)"
    }

    func offerDuration(periodCount: Int) -> String {
        let total = value * periodCount
        switch unit {
        case .day:
            return "\(total) 天"
        case .week:
            // 用户更容易理解首购试用的实际天数。
            return "\(total * 7) 天"
        case .month:
            return "\(total) 个月"
        case .year:
            return total == 1 ? "1 年" : "\(total) 年"
        case .unknown:
            return "\(total) 个优惠周期"
        }
    }
}

private extension PaymentRenewalState {
    var displayName: String {
        switch self {
        case .subscribed: "有效"
        case .expired: "已过期"
        case .inBillingRetryPeriod: "账单重试"
        case .inGracePeriod: "宽限期"
        case .revoked: "已撤销"
        case .unknown(let value): "未知（\(value)）"
        }
    }
}

private extension MockBackendResult {
    var displayName: String {
        switch self {
        case .processed: "处理完成"
        case .duplicate: "幂等命中"
        case .offline: "离线失败"
        case .timeout: "请求超时"
        case .clientError: "4xx 拒绝"
        case .serverError: "5xx 失败"
        case .successThenDisconnected: "成功后断连"
        case .persistenceFailed: "账本失败"
        }
    }

    var color: Color {
        switch self {
        case .processed: .green
        case .duplicate: .blue
        case .offline, .timeout, .clientError, .serverError, .persistenceFailed: .orange
        case .successThenDisconnected: .purple
        }
    }
}

private extension MockBackendFaultMode {
    var displayName: String {
        switch self {
        case .normal: "正常"
        case .offline: "离线"
        case .timeout: "超时"
        case .clientError: "4xx"
        case .serverError: "5xx"
        case .successThenDisconnect: "成功后断连"
        }
    }
}

#Preview {
    ContentView(model: .preview())
}
