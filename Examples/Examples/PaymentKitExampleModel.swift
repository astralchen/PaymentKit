import Combine
import Foundation
import PaymentKit

#if os(iOS)
import StoreKit
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 示例程序使用的 StoreKit 商品标识符。
enum ExampleProducts {
    /// Sandbox 优惠代码唯一适用的年订阅商品。
    static let yearly = "paymentkit.demo.yearly"

    /// 按 `.storekit` 配置文件顺序排列的全部商品。
    static let all = [
        "paymentkit.demo.coins100",
        "paymentkit.demo.lifetime",
        "paymentkit.demo.monthly",
        yearly,
    ]
}

/// 示例主应用与扩展共用的可靠交付存储。
enum ExamplePaymentStorage {
    /// Developer Portal 中绑定到两个 target 的 App Group。
    static let groupIdentifier = "group.com.paymentkit.examples"

    /// 主应用和扩展必须保持完全一致的存储命名空间。
    static let namespace = "com.paymentkit.examples.payment-outbox"

    /// 返回共享 SQLite outbox 配置。
    static var configuration: PaymentStorageConfiguration {
        .appGroup(identifier: groupIdentifier, namespace: namespace)
    }
}

#if DEBUG
private enum ConcurrentOutboxProbeTiming {
    static let timeoutNanoseconds: UInt64 = 25_000_000_000
    static let pollingIntervalNanoseconds: UInt64 = 200_000_000
}
#endif

/// 在 StoreKit 系统界面返回后按可靠顺序协调示例状态。
///
/// 此类型只负责示例状态编排，不决定商品权益，也不会调用 `AppStore.sync()`。
@MainActor
struct StoreKitPresentationReconciler {
    private let reloadStoreSession: @MainActor () async -> PaymentSnapshot
    private let reloadBackend: @MainActor () async -> Void

    /// 创建系统界面返回协调器。
    ///
    /// - Parameters:
    ///   - reloadStoreSession: 重建 StoreKit 序列并读取新会话状态。
    ///   - reloadBackend: 读取共享模拟后台快照。
    init(
        reloadStoreSession: @escaping @MainActor () async -> PaymentSnapshot,
        reloadBackend: @escaping @MainActor () async -> Void
    ) {
        self.reloadStoreSession = reloadStoreSession
        self.reloadBackend = reloadBackend
    }

    /// 执行一次完整的系统界面返回协调。
    ///
    /// 热重载会先重建 StoreKit 监听并重放可靠 outbox；弱网时 PaymentClient 保留
    /// 最近已验证快照。后台快照随后读取，以反映已经发生的幂等交付或处理失败。
    func reconcile() async -> PaymentSnapshot {
        let snapshot = await reloadStoreSession()
        await reloadBackend()
        return snapshot
    }
}

/// 按 StoreKit 签名事件顺序维护顶部脱敏交易诊断状态。
@MainActor
struct ExampleTransactionDiagnosticStatus {
    private struct EventOrder: Equatable {
        let signedDate: Date
        let purchaseDate: Date
        let transactionID: UInt64

        /// 返回当前签名事件是否严格晚于另一事件。
        func isLater(than other: Self) -> Bool {
            if signedDate != other.signedDate {
                return signedDate > other.signedDate
            }
            if purchaseDate != other.purchaseDate {
                return purchaseDate > other.purchaseDate
            }
            return transactionID > other.transactionID
        }
    }

    private var latestOrder: EventOrder?
    private var latestFinishState: PaymentFinishState?

    /// 当前最新交易对应的脱敏诊断文案。
    private(set) var message: String?

    /// 记录一个可靠交付结果。
    ///
    /// StoreKit 启动重放和实时监听可能交错完成。较旧签名不能覆盖较新交易；
    /// 同一签名事件只允许从等待 StoreKit 升级为已经完成 `finish()`。
    ///
    /// - Returns: 状态发生前向变化时返回新文案，否则返回 `nil`。
    mutating func record(
        _ transaction: PaymentTransaction,
        finishState: PaymentFinishState
    ) -> String? {
        let order = EventOrder(
            signedDate: transaction.signedDate,
            purchaseDate: transaction.purchaseDate,
            transactionID: transaction.id
        )

        if let latestOrder {
            if order == latestOrder {
                guard
                    latestFinishState == .awaitingStoreKit,
                    finishState == .finished
                else {
                    return nil
                }
            } else {
                guard order.isLater(than: latestOrder) else { return nil }
            }
        }

        self.latestOrder = order
        latestFinishState = finishState
        let suffix = String(transaction.id).suffix(6)
        let newMessage = switch finishState {
        case .finished:
            "交易已交付并 finish：…\(suffix)"
        case .awaitingStoreKit:
            "交易已交付，等待 StoreKit finish：…\(suffix)"
        }
        message = newMessage
        return newMessage
    }
}

/// 将 PaymentKit 事件提交给示例界面及共享模拟后台。
@MainActor
struct ExamplePaymentEventReceiver {
    private let updateSnapshot: @MainActor (PaymentSnapshot) -> Void
    private let prependEvent: @MainActor (String) -> Void
    private let updateTransactionStatus:
        @MainActor (PaymentTransaction, PaymentFinishState) -> Void
    private let reloadBackend: @MainActor () async -> Void

    /// 创建事件接收器。
    init(
        updateSnapshot: @escaping @MainActor (PaymentSnapshot) -> Void,
        prependEvent: @escaping @MainActor (String) -> Void,
        updateTransactionStatus: @escaping @MainActor (
            PaymentTransaction,
            PaymentFinishState
        ) -> Void = { _, _ in },
        reloadBackend: @escaping @MainActor () async -> Void
    ) {
        self.updateSnapshot = updateSnapshot
        self.prependEvent = prependEvent
        self.updateTransactionStatus = updateTransactionStatus
        self.reloadBackend = reloadBackend
    }

    /// 接收一个仅用于界面与诊断的 PaymentKit 事件。
    func receive(_ event: PaymentEvent) async {
        switch event {
        case .snapshotUpdated(let snapshot):
            // 框架快照可以直接提交；该事件本身不表示后台账本发生变化。
            updateSnapshot(snapshot)
            prependEvent("状态快照已更新")
        case .purchasePending(let productID):
            prependEvent("购买等待批准：\(productID)")
        case .transactionDelivered(let transaction, let finishState):
            let state = finishState == .finished ? "已 finish" : "等待 StoreKit"
            prependEvent(
                "交易已交付（\(state)）：\(transaction.productID) …\(String(transaction.id).suffix(6))"
            )
            // 顶部运行状态同样跟随最新可靠交付，不能永久停留在首购交易。
            updateTransactionStatus(transaction, finishState)
            await reloadBackend()
        case .transactionProcessingFailed(let transaction, _):
            prependEvent("交易处理失败并保留：\(transaction.productID)")
            await reloadBackend()
        case .verificationFailed(let transactionID, _):
            let suffix = transactionID.map { String(String($0).suffix(6)) } ?? "未知"
            prependEvent("StoreKit 验签失败：…\(suffix)")
        case .restoreCompleted:
            prependEvent("用户恢复购买完成")
        }
    }
}

/// 按调用方明确指定的边界防止并发 StoreKit 系统界面操作。
///
/// 可等待关闭的平台可把完整异步展示纳入边界；iOS 15 没有关闭信号，
/// 因此调用方只能把同步展示调用纳入边界。
@MainActor
final class StoreKitPresentationSingleFlight {
    private var isPerforming = false

    /// 在当前没有系统界面操作时执行任务。
    ///
    /// - Returns: 本次任务是否被接受。已有任务在途时返回 `false`。
    @discardableResult
    func perform(
        _ operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        guard !isPerforming else { return false }
        isPerforming = true
        defer { isPerforming = false }
        await operation()
        return true
    }
}

/// 已经取得有效平台展示上下文的 Sandbox 优惠代码系统页操作。
typealias SandboxOfferCodeSystemPresentation = @MainActor () async throws -> Void

/// 已准备好的系统展示，以及平台能否通知兑换页关闭。
enum SandboxOfferCodePreparedPresentation {
    case waitsForDismissal(SandboxOfferCodeSystemPresentation)
    case opensWithoutDismissalSignal(SandboxOfferCodeSystemPresentation)
}

/// 只含安全展示字段、不承载完整代码的 Sandbox 优惠代码投影。
nonisolated struct SandboxOfferCodeDisplayItem: Identifiable, Hashable, Sendable {
    let id: Int
    let displayName: String
}

/// 在写入剪贴板前取得有效系统兑换页展示上下文的依赖边界。
@MainActor
protocol SandboxOfferCodeRedeemSheetPresenting: AnyObject {
    /// 验证并捕获当前可用的系统展示上下文。
    func preparedPresentation() throws -> SandboxOfferCodePreparedPresentation
}

#if os(iOS)
typealias SandboxOfferCodePresentationContext = UIWindowScene
#elseif os(macOS)
typealias SandboxOfferCodePresentationContext = NSViewController
#endif

/// 取得当前平台有效前台展示上下文的最窄依赖边界。
typealias SandboxOfferCodePresentationContextProvider =
    @MainActor () -> SandboxOfferCodePresentationContext?

/// 使用当前前台窗口展示 Sandbox 优惠代码系统兑换页。
@MainActor
final class SystemSandboxOfferCodeRedeemSheetPresenter:
    SandboxOfferCodeRedeemSheetPresenting {
    private let contextProvider: SandboxOfferCodePresentationContextProvider

    /// 创建使用系统前台 active 上下文查询的 presenter。
    init() {
        contextProvider = Self.defaultContextProvider
    }

    /// 创建使用指定上下文查询的 presenter。
    init(
        contextProvider: @escaping SandboxOfferCodePresentationContextProvider
    ) {
        self.contextProvider = contextProvider
    }

    /// 验证并捕获当前可用的系统展示上下文。
    func preparedPresentation() throws -> SandboxOfferCodePreparedPresentation {
#if os(iOS)
        guard let scene = contextProvider() else {
            throw ExampleInputError.sandboxOfferCodePresentationUnavailable
        }
        if #available(iOS 16.0, *) {
            return .waitsForDismissal { [scene] in
                try await PaymentPresentation.presentOfferCodeRedeemSheet(
                    in: scene
                )
            }
        }
        return .opensWithoutDismissalSignal { [scene] in
            // iOS 15 只提供同步展示调用，没有系统页关闭信号。
            withExtendedLifetime(scene) {
                SKPaymentQueue.default().presentCodeRedemptionSheet()
            }
        }
#elseif os(macOS)
        guard let viewController = contextProvider() else {
            throw ExampleInputError.sandboxOfferCodePresentationUnavailable
        }
        return .waitsForDismissal { [viewController] in
            try await PaymentPresentation.presentOfferCodeRedeemSheet(in: viewController)
        }
#endif
    }

    /// 返回当前平台可用于系统页展示的前台 active 上下文。
    private static func defaultContextProvider()
        -> SandboxOfferCodePresentationContext? {
#if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
#elseif os(macOS)
        NSApplication.shared.keyWindow?.contentViewController
#endif
    }
}

/// 示例界面允许用户明确选择的一种购买优惠。
enum ExampleOfferChoice: Hashable, Identifiable {
    case standard
    case introductory
    case promotional(String)
    case winBack(String)
    case sandboxOfferCode(id: Int, displayName: String)

    var id: String {
        switch self {
        case .standard: "standard"
        case .introductory: "introductory"
        case .promotional(let offerID): "promotional:\(offerID)"
        case .winBack(let offerID): "winBack:\(offerID)"
        case .sandboxOfferCode(let id, _): "sandbox-offer-code:\(id)"
        }
    }
}

/// 驱动 PaymentKit 示例界面的状态模型。
@MainActor
final class PaymentKitExampleModel: ObservableObject {
    /// PaymentKit 最近一次状态快照。
    @Published private(set) var snapshot = PaymentSnapshot.empty

    /// 模拟后台最近一次状态快照。
    @Published private(set) var backendSnapshot = MockBackendSnapshot(
        isOnline: true,
        faultMode: .normal,
        latencyMilliseconds: 0,
        signedEventCount: 0,
        businessDeliveryCount: 0,
        records: []
    )

    /// 当前是否正在执行用户操作。
    @Published private(set) var isBusy = false

    /// 是否为下一笔 sandbox 购买附加 Ask to Buy 模拟选项。
    @Published var simulatesAskToBuy = false

    /// 最近一次面向用户的操作结果。
    @Published private(set) var statusMessage = "正在等待 PaymentKit 启动"

    /// 当前需要展示的错误。
    @Published var errorMessage: String?

    /// 最近收到的框架事件，最新事件排在最前。
    @Published private(set) var events: [String] = []

    /// 用户为各订阅商品选择的账单计划。
    @Published private(set) var selectedBillingPlans: [String: PaymentBillingPlan] = [:]

    /// 用户为各订阅商品选择的单一优惠。
    @Published private(set) var selectedOffers: [String: ExampleOfferChoice] = [:]

    /// 主应用 Bundle 中可用于当前 Sandbox 会话的完整优惠代码目录。
    private let sandboxOfferCodeCatalog: SandboxOfferCodeCatalog

    /// 按目录顺序公开的脱敏 Sandbox 优惠代码。
    var sandboxOfferCodes: [SandboxOfferCodeDisplayItem] {
        sandboxOfferCodeCatalog.codes.map {
            SandboxOfferCodeDisplayItem(
                id: $0.id,
                displayName: $0.displayName
            )
        }
    }

    /// 不含任何完整代码的目录加载状态。
    var sandboxOfferCodeCatalogStatus: SandboxOfferCodeCatalogStatus {
        sandboxOfferCodeCatalog.status
    }

    /// 不含任何完整代码的非法行计数。
    var sandboxOfferCodeInvalidLineCount: Int {
        sandboxOfferCodeCatalog.invalidLineCount
    }

    /// 不含任何完整代码的重复行计数。
    var sandboxOfferCodeDuplicateLineCount: Int {
        sandboxOfferCodeCatalog.duplicateLineCount
    }

    /// 开发工具签发的促销授权，仅保存在当前进程内存中。
    @Published var promotionalAuthorizationJWS = ""

    /// 等待界面决定接受或放弃的 App Store 外部购买意图。
    @Published private(set) var purchaseIntents: [PaymentPurchaseIntent] = []

    /// 调用方明确接管后等待系统展示的 App Store 消息。
    @Published private(set) var storeMessages: [PaymentStoreMessage] = []

    /// 是否已经明确接管 StoreKit 系统消息。
    @Published private(set) var interceptsStoreMessages = false

    private let client: PaymentClient
    private let backend: MockTransactionProcessor
    private let startsAutomatically: Bool
    private let sandboxOfferCodeRedemption: SandboxOfferCodeRedemptionCoordinator
    private let sandboxOfferCodePresenter: any SandboxOfferCodeRedeemSheetPresenting
    private let sandboxOfferCodeReconciliation: (@MainActor () async -> Void)?
    private let sandboxOfferCodeNow: @MainActor () -> Date
    private let storeKitPresentationSingleFlight = StoreKitPresentationSingleFlight()
    private var eventTask: Task<Void, Never>?
    private var purchaseIntentTask: Task<Void, Never>?
    private var storeMessageTask: Task<Void, Never>?
    private var backendConfigurationTask: Task<Void, Never>?
    private var backendConfigurationRevision: UInt64 = 0
    private var transactionDiagnosticStatus = ExampleTransactionDiagnosticStatus()
    #if DEBUG && os(iOS)
    @Published private(set) var isConcurrentOutboxProbeArmed = false
    private var concurrentOutboxProbeTask: Task<Void, Never>?
    private var concurrentOutboxBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var hasStarted = false

    /// 创建示例状态模型。
    ///
    /// - Parameters:
    ///   - client: PaymentKit 支付客户端。
    ///   - backend: 示例使用的模拟后台。
    ///   - startsAutomatically: 视图出现时是否连接 StoreKit。
    ///   - sandboxOfferCodeCatalog: 在模型内部私有保存的 Sandbox 优惠代码目录。
    ///   - sandboxOfferCodeClipboard: 临时保存完整代码的剪贴板依赖。
    ///   - sandboxOfferCodePresenter: 在写入剪贴板前准备系统展示上下文的依赖。
    ///   - sandboxOfferCodeReconciliation: 测试可替换的兑换页返回协调操作。
    init(
        client: PaymentClient,
        backend: MockTransactionProcessor,
        startsAutomatically: Bool = true,
        sandboxOfferCodeCatalog: SandboxOfferCodeCatalog = .missing,
        sandboxOfferCodeClipboard: (any SandboxOfferCodeClipboard)? = nil,
        sandboxOfferCodePresenter: (any SandboxOfferCodeRedeemSheetPresenting)? = nil,
        sandboxOfferCodeReconciliation: (@MainActor () async -> Void)? = nil,
        sandboxOfferCodeNow: @escaping @MainActor () -> Date = Date.init
    ) {
        self.client = client
        self.backend = backend
        self.startsAutomatically = startsAutomatically
        self.sandboxOfferCodeCatalog = sandboxOfferCodeCatalog
        self.sandboxOfferCodeRedemption = SandboxOfferCodeRedemptionCoordinator(
            clipboard: sandboxOfferCodeClipboard ?? SystemSandboxOfferCodeClipboard()
        )
        self.sandboxOfferCodePresenter = sandboxOfferCodePresenter
            ?? SystemSandboxOfferCodeRedeemSheetPresenter()
        self.sandboxOfferCodeReconciliation = sandboxOfferCodeReconciliation
        self.sandboxOfferCodeNow = sandboxOfferCodeNow
    }

    /// 创建运行示例所需的默认对象图。
    static func live() throws -> PaymentKitExampleModel {
        let databaseURL = try SharedMockBackendStorage.databaseURL(
            appGroupIdentifier: ExamplePaymentStorage.groupIdentifier
        )
        let backend = MockTransactionProcessor(databaseURL: databaseURL)
        let client = try PaymentClient(
            configuration: PaymentConfiguration(productIDs: ExampleProducts.all),
            processor: backend,
            storage: ExamplePaymentStorage.configuration
        )
        let isRunningTests = ProcessInfo.processInfo.environment.keys.contains {
            $0.hasPrefix("XCTest")
        }
        return PaymentKitExampleModel(
            client: client,
            backend: backend,
            startsAutomatically: !isRunningTests,
            sandboxOfferCodeCatalog: SandboxOfferCodeCatalog.loadForAppLaunch(
                from: Bundle.main
            )
        )
    }

    /// 创建明确报告 App Group 配置失败且不会连接 StoreKit 的模型。
    static func storageConfigurationFailure() -> PaymentKitExampleModel {
        let model = preview()
        model.statusMessage = "共享 outbox 配置失败，PaymentKit 未启动"
        model.errorMessage = "无法访问 group.com.paymentkit.examples，请检查签名与 App Group entitlement"
        return model
    }

    /// 创建不会访问 StoreKit 的预览模型。
    static func preview() -> PaymentKitExampleModel {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaymentKitPreview-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("mock-backend.sqlite3", isDirectory: false)
        let backend = MockTransactionProcessor(
            latencyMilliseconds: 0,
            databaseURL: databaseURL
        )
        let client = PaymentClient(
            configuration: PaymentConfiguration(productIDs: []),
            processor: backend,
            logger: DisabledPaymentLogHandler()
        )
        let model = PaymentKitExampleModel(
            client: client,
            backend: backend,
            startsAutomatically: false,
            sandboxOfferCodeCatalog: .missing
        )
        model.statusMessage = "预览模式不会连接 StoreKit"
        return model
    }

    /// 在应用生命周期开始时启动 PaymentKit。
    func startIfNeeded() async {
        guard startsAutomatically, !hasStarted else { return }
        hasStarted = true
        isBusy = true

        // 先订阅框架事件，再启动客户端，避免界面遗漏首个状态快照。
        eventTask = Task { [weak self, client] in
            let stream = await client.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
        purchaseIntentTask = Task { [weak self, client] in
            let stream = await client.purchaseIntents()
            for await intent in stream {
                guard !Task.isCancelled else { return }
                self?.receive(intent)
            }
        }
        statusMessage = "PaymentKit 已启动并监听交易"
        await client.start()
        snapshot = await client.snapshot()
        establishDefaultPurchaseSelections()
        await reloadBackendSnapshot()
        isBusy = false
    }

    /// 重新加载商品和支付状态。
    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        do {
            snapshot = try await client.refresh()
            establishDefaultPurchaseSelections()
            statusMessage = "商品与交易状态已刷新"
        } catch {
            present(error)
        }
        await reloadBackendSnapshot()
    }

    /// 购买指定商品。
    ///
    /// - Parameter product: 用户选择的商品。
    func purchase(_ product: PaymentProduct) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let options = try purchaseOptions(for: product)
            let outcome = try await client.purchase(
                productID: product.id,
                options: options
            )
            switch outcome {
            case .completed(let transaction):
                updateTransactionStatus(transaction, finishState: .finished)
            case .pending:
                statusMessage = "购买等待 Ask to Buy 或其他外部批准"
            case .cancelled:
                statusMessage = "用户取消了购买"
            }
        } catch {
            // 处理器失败时主动刷新，确保 unfinished 交易立即显示在示例界面。
            _ = try? await client.refresh()
            present(error)
        }
        snapshot = await client.snapshot()
        await reloadBackendSnapshot()
    }

    /// 选择商品使用的账单计划。
    func selectBillingPlan(_ plan: PaymentBillingPlan, for productID: String) {
        selectedBillingPlans[productID] = plan

        // 切换计划后，原优惠可能不适用于新计划；回退到标准价格最安全。
        selectedOffers[productID] = .standard
    }

    /// 选择商品使用的单一优惠。
    func selectOffer(_ offer: ExampleOfferChoice, for productID: String) {
        selectedOffers[productID] = offer
        if case .sandboxOfferCode = offer {
            // 优惠代码由系统兑换，示例固定展示 App Store 配置的年付预付方案。
            selectedBillingPlans[productID] = .upFront
        }
    }

    /// 返回当前商品实际选择的账单计划。
    func selectedBillingPlan(for product: PaymentProduct) -> PaymentBillingPlan? {
        selectedBillingPlans[product.id]
            ?? product.subscription?.pricingTerms.first?.billingPlan
    }

    /// 返回当前商品实际选择的优惠。
    func selectedOffer(for product: PaymentProduct) -> ExampleOfferChoice {
        let candidate = selectedOffers[product.id] ?? defaultOffer(for: product)

        // Sandbox 优惠代码不是 Product.purchase 选项，必须保留给兑换流程做
        // 商品和目录的明确校验，不能静默降级为一次普通购买。
        if case .sandboxOfferCode = candidate {
            return candidate
        }

        // 商品刷新或账单计划切换后，旧选择可能已不再属于当前计划。
        // 必须重新采用当前商品的默认优惠，避免把其他计划的优惠带入交易，
        // 也避免对符合首购资格的账户展示 StoreKit 无法兑现的标准价选择。
        return availableOffers(for: product).contains(candidate)
            ? candidate
            : defaultOffer(for: product)
    }

    /// 返回当前账单计划能够使用的优惠选择。
    func availableOffers(for product: PaymentProduct) -> [ExampleOfferChoice] {
        guard let subscription = product.subscription else { return [.standard] }
        let selectedPlan = selectedBillingPlan(for: product)
        let termOffers = subscription.pricingTerms
            .first { $0.billingPlan == selectedPlan }?
            .offers
            ?? []
        var choices: [ExampleOfferChoice] = []
        if subscription.isEligibleForIntroductoryOffer,
           termOffers.contains(where: { $0.type == .introductory }) {
            // 使用 Apple 本机资格时，StoreKit 会自动应用当前定价方案的首购优惠。
            // 因此标准价格不是可兑现的退出选项，界面必须直接展示实际结算价格。
            choices.append(.introductory)
        } else {
            choices.append(.standard)
        }
        choices.append(
            contentsOf: termOffers.compactMap { offer in
                guard let offerID = offer.id else { return nil }
                switch offer.type {
                case .promotional:
                    return .promotional(offerID)
                case .winBack where eligibleWinBackOfferIDs.contains(offerID):
                    return .winBack(offerID)
                default:
                    return nil
                }
            }
        )
        if product.id == ExampleProducts.yearly {
            // 完整代码仍封装在目录中，选择状态只保存整数 id 和脱敏文案。
            choices.append(contentsOf: sandboxOfferCodes.map {
                .sandboxOfferCode(id: $0.id, displayName: $0.displayName)
            })
        }
        return choices
    }

    /// 根据当前优惠选择执行商品的统一主操作。
    func performPrimaryAction(for product: PaymentProduct) async {
        switch selectedOffer(for: product) {
        case .sandboxOfferCode(let id, _):
            await redeemSandboxOfferCode(id: id, for: product)
        default:
            await purchase(product)
        }
    }

    /// 返回界面中可用的回归优惠标识符，保持 Apple 的优先级顺序。
    var eligibleWinBackOfferIDs: [String] {
        var seen = Set<String>()
        return snapshot.subscriptionStatuses
            .flatMap(\.renewalInfo.eligibleWinBackOfferIDs)
            .filter { seen.insert($0).inserted }
    }

    /// 接受一项 App Store 外部购买意图。
    func accept(_ intent: PaymentPurchaseIntent) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let outcome = try await client.purchase(intent: intent)
            purchaseIntents.removeAll { $0.id == intent.id }
            switch outcome {
            case .completed(let transaction):
                statusMessage = "外部购买已完成：…\(String(transaction.id).suffix(6))"
            case .pending:
                statusMessage = "外部购买等待批准"
            case .cancelled:
                statusMessage = "用户取消了外部购买"
            }
        } catch {
            present(error)
        }
        snapshot = await client.snapshot()
        await reloadBackendSnapshot()
    }

    /// 在当前界面放弃一项外部购买意图。
    ///
    /// 框架会从当前客户端移除该意图；已经由 StoreKit 完成的交易仍由交易监听处理。
    func abandon(_ intent: PaymentPurchaseIntent) async {
        if await client.discardPurchaseIntent(intent) {
            purchaseIntents.removeAll { $0.id == intent.id }
            statusMessage = "已放弃当前购买意图"
        } else {
            statusMessage = "购买意图已经处理或不再可用"
        }
    }

    /// 明确接管 StoreKit 系统消息的展示时机。
    func enableStoreMessageInterception() {
        guard !interceptsStoreMessages else { return }
        interceptsStoreMessages = true
        storeMessageTask = Task { [weak self, client] in
            let stream = await client.storeMessages()
            for await message in stream {
                guard !Task.isCancelled else { return }
                self?.storeMessages.append(message)
            }
        }
        statusMessage = "已接管 StoreKit 系统消息；未手动展示的消息会保持延迟"
    }

    /// 让系统展示一项已经接管的 App Store 消息。
    func display(_ message: PaymentStoreMessage) async {
        await performStoreKitPresentation { [self] in
#if os(iOS)
            guard let scene = activeWindowScene else {
                errorMessage = "当前没有可用于展示系统消息的 UIWindowScene"
                return
            }
            do {
                try PaymentPresentation.displayStoreMessage(message, in: scene)
                storeMessages.removeAll { $0.id == message.id }
                statusMessage = "StoreKit 系统消息已展示"
                await reconcileAfterStoreKitPresentation()
            } catch {
                present(error)
            }
#else
            errorMessage = "当前 PaymentKit 系统消息展示入口仅支持 iOS"
#endif
        }
    }

    /// 展示优惠代码兑换系统页。
    func redeemOfferCode() async {
        await performStoreKitPresentation { [self] in
            do {
#if os(iOS)
                guard let scene = activeWindowScene else {
                    errorMessage = "当前没有可用于展示优惠代码兑换页的 UIWindowScene"
                    return
                }
                try await PaymentPresentation.presentOfferCodeRedeemSheet(in: scene)
#elseif os(macOS)
                guard let viewController = NSApplication.shared.keyWindow?.contentViewController else {
                    errorMessage = "当前没有可用于展示优惠代码兑换页的 NSViewController"
                    return
                }
                try await PaymentPresentation.presentOfferCodeRedeemSheet(in: viewController)
#endif
                statusMessage = "优惠代码兑换页已关闭；后续交易由监听器可靠处理"
                await reconcileAfterStoreKitPresentation()
            } catch {
                present(error)
            }
        }
    }

    /// 使用目录中的私有值兑换指定 Sandbox 优惠代码。
    private func redeemSandboxOfferCode(id: Int, for product: PaymentProduct) async {
        guard !isBusy else { return }
        guard product.id == ExampleProducts.yearly else {
            present(ExampleInputError.sandboxOfferCodeRequiresYearlyProduct)
            return
        }
        guard let code = sandboxOfferCodeCatalog.secretValue(for: id) else {
            present(ExampleInputError.sandboxOfferCodeUnavailable)
            return
        }

        let preparedPresentation: SandboxOfferCodePreparedPresentation
        do {
            // 必须先取得有效上下文，之后协调器才获准把完整代码写入剪贴板。
            preparedPresentation = try sandboxOfferCodePresenter
                .preparedPresentation()
        } catch {
            present(ExampleInputError.sandboxOfferCodePresentationUnavailable)
            return
        }

        switch preparedPresentation {
        case .waitsForDismissal(let presentation):
            await redeemSandboxOfferCodeAndWaitForDismissal(
                code,
                presentation: presentation
            )
        case .opensWithoutDismissalSignal(let presentation):
            await openLegacySandboxOfferCodeSheet(
                code,
                presentation: presentation
            )
        }
    }

    /// 在能等待系统页关闭的平台，把展示、清理和协调纳入同一个在途操作。
    private func redeemSandboxOfferCodeAndWaitForDismissal(
        _ code: String,
        presentation: @escaping SandboxOfferCodeSystemPresentation
    ) async {
        await performStoreKitPresentation { [self] in
            let succeeded = await attemptSandboxOfferCodePresentation(
                code,
                clipboardPolicy: .clearIfUnchangedAfterPresentation,
                presentation: presentation
            )
            await reconcileAfterSandboxOfferCodePresentation()
            finishSandboxOfferCodePresentation(
                succeeded: succeeded,
                successMessage: "Sandbox 优惠代码兑换页已关闭"
            )
        }
    }

    /// iOS 15 无关闭信号：single-flight 只覆盖展示调用，协调在其释放后执行。
    private func openLegacySandboxOfferCodeSheet(
        _ code: String,
        presentation: @escaping SandboxOfferCodeSystemPresentation
    ) async {
        var presentationSucceeded: Bool?
        let accepted = await storeKitPresentationSingleFlight.perform { [self] in
            isBusy = true
            defer { isBusy = false }
            presentationSucceeded = await attemptSandboxOfferCodePresentation(
                code,
                clipboardPolicy: .localOnly(
                    expirationDate: sandboxOfferCodeNow()
                        .addingTimeInterval(5 * 60)
                ),
                presentation: presentation
            )
        }
        guard accepted, let presentationSucceeded else { return }

        await reconcileAfterSandboxOfferCodePresentation()
        finishSandboxOfferCodePresentation(
            succeeded: presentationSucceeded,
            successMessage: "Sandbox 优惠代码兑换页已打开"
        )
    }

    /// 执行一次已开始的展示尝试；失败详情不会进入界面或日志。
    private func attemptSandboxOfferCodePresentation(
        _ code: String,
        clipboardPolicy: SandboxOfferCodeClipboardPolicy,
        presentation: @escaping SandboxOfferCodeSystemPresentation
    ) async -> Bool {
        do {
            try await sandboxOfferCodeRedemption.redeem(
                code,
                clipboardPolicy: clipboardPolicy,
                presentSystemSheet: presentation
            )
            return true
        } catch {
            return false
        }
    }

    /// 已开始展示后，无论成功、失败或取消都执行可靠状态协调。
    private func reconcileAfterSandboxOfferCodePresentation() async {
        if let sandboxOfferCodeReconciliation {
            await sandboxOfferCodeReconciliation()
        } else {
            await reconcileAfterStoreKitPresentation()
        }
    }

    /// 以固定非敏感文案提交系统展示结果。
    private func finishSandboxOfferCodePresentation(
        succeeded: Bool,
        successMessage: String
    ) {
        if succeeded {
            errorMessage = nil
            statusMessage = successMessage
        } else {
            present(ExampleInputError.sandboxOfferCodePresentationFailed)
        }
    }

    /// 由明确的用户操作恢复购买。
    func restorePurchases() async {
        isBusy = true
        defer { isBusy = false }
        do {
            snapshot = try await client.restorePurchases()
            statusMessage = "App Store 同步与恢复已完成"
        } catch {
            present(error)
        }
        await reloadBackendSnapshot()
    }

    /// 重试处理所有未完成交易。
    func retryUnfinishedTransactions() async {
        isBusy = true
        defer { isBusy = false }
        let report = await client.retryUnfinishedTransactions()
        snapshot = report.snapshot
        await reloadBackendSnapshot()
        statusMessage = snapshot.pendingTransactions.isEmpty
            ? "重试完成：交付 \(report.deliveredCount)，finish \(report.finishedCount)"
            : "仍有 \(snapshot.pendingTransactions.count) 笔交易待处理"
    }

    /// 设置模拟后台是否联网。
    ///
    /// - Parameter isOnline: 新的联网状态。
    func setBackendOnline(_ isOnline: Bool) {
        let mode: MockBackendFaultMode = isOnline ? .normal : .offline
        // Toggle 的 Binding 必须立即得到新值，否则 SwiftUI 会在 actor 回写前弹回旧状态。
        backendSnapshot = MockBackendSnapshot(
            isOnline: isOnline,
            faultMode: mode,
            latencyMilliseconds: backendSnapshot.latencyMilliseconds,
            signedEventCount: backendSnapshot.signedEventCount,
            businessDeliveryCount: backendSnapshot.businessDeliveryCount,
            records: backendSnapshot.records
        )
        scheduleBackendConfiguration(mode)
    }

    /// 设置模拟后台故障注入模式。
    ///
    /// - Parameter mode: 后续请求使用的故障模式。
    func setBackendFaultMode(_ mode: MockBackendFaultMode) {
        backendSnapshot = MockBackendSnapshot(
            isOnline: mode != .offline,
            faultMode: mode,
            latencyMilliseconds: backendSnapshot.latencyMilliseconds,
            signedEventCount: backendSnapshot.signedEventCount,
            businessDeliveryCount: backendSnapshot.businessDeliveryCount,
            records: backendSnapshot.records
        )
        scheduleBackendConfiguration(mode)
    }

    /// 将最新故障模式提交给模拟后台，并在恢复正常时自动重放可靠 outbox。
    ///
    /// 快速连续切换模式时，旧任务会被取消且不能覆盖最新界面状态。PaymentClient
    /// 仍负责“交付、标记、finish、清理”的顺序，示例不直接修改 SQLite。
    ///
    /// - Parameter mode: 后续模拟后台请求使用的故障模式。
    private func scheduleBackendConfiguration(_ mode: MockBackendFaultMode) {
        backendConfigurationRevision &+= 1
        let revision = backendConfigurationRevision
        backendConfigurationTask?.cancel()
        backendConfigurationTask = Task { [weak self, backend] in
            await backend.setFaultMode(mode)
            guard !Task.isCancelled, let self else { return }

            let report: PaymentRetryReport?
            if mode == .normal {
                // 后台恢复属于可靠重放触发源；不依赖前台通知、诊断刷新或用户按钮。
                report = await self.client.retryUnfinishedTransactions()
            } else {
                report = nil
            }
            guard !Task.isCancelled else { return }

            let latestBackendSnapshot = await backend.snapshot()
            guard !Task.isCancelled,
                  revision == self.backendConfigurationRevision
            else { return }

            self.backendSnapshot = latestBackendSnapshot
            if let report {
                self.snapshot = report.snapshot
                let remainingCount = report.snapshot.pendingTransactions.count
                if report.failureCount == 0,
                   report.unresolvedCount == 0,
                   remainingCount == 0 {
                    self.errorMessage = nil
                    self.statusMessage =
                        "后台已恢复，outbox 自动重试完成：交付 \(report.deliveredCount)，finish \(report.finishedCount)"
                } else {
                    self.statusMessage = "后台已恢复，仍有 \(remainingCount) 笔交易待处理"
                }
            }
            if revision == self.backendConfigurationRevision {
                self.backendConfigurationTask = nil
            }
        }
    }

#if DEBUG
    /// 等待并发 outbox 探针信号；轮询和超时任务中先完成的一方决定结果。
    nonisolated static func waitForConcurrentOutboxProbeSignal(
        timeoutNanoseconds: UInt64,
        pollingIntervalNanoseconds: UInt64,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if await condition() { return true }
                    do {
                        try await Task.sleep(
                            nanoseconds: pollingIntervalNanoseconds
                        )
                    } catch {
                        return false
                    }
                }
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return false
                } catch {
                    return false
                }
            }

            let wasSignaled = await group.next() ?? false
            group.cancelAll()
            return wasSignaled
        }
    }
#endif

#if DEBUG && os(iOS)
    /// 准备主 App 在后台与 Share Extension 并发重试同一 outbox。
    ///
    /// 该探针只存在于 Debug 示例。主 App 申请一次有限后台执行窗口，等待共享模拟后台
    /// 的签名事件计数增加；这表示扩展已经提交后台事务。随后主 App 将自己的模拟后台
    /// 恢复正常，并立即通过 PaymentClient 重放 outbox。
    func armConcurrentOutboxProbe() {
        guard !isConcurrentOutboxProbeArmed else { return }

        let baselineSignedEventCount = backendSnapshot.signedEventCount
        isConcurrentOutboxProbeArmed = true
        statusMessage = "并发探针已准备：请在 25 秒内从分享扩展开始重试"
        concurrentOutboxBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "PaymentKitConcurrentOutboxProbe"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.concurrentOutboxProbeTask?.cancel()
                self.finishConcurrentOutboxProbe()
                self.statusMessage = "并发探针后台时间已结束，未修改交易状态"
            }
        }

        concurrentOutboxProbeTask = Task { [weak self, backend, client] in
            guard let self else { return }
            defer { self.finishConcurrentOutboxProbe() }

            do {
                let wasSignaled = await Self.waitForConcurrentOutboxProbeSignal(
                    timeoutNanoseconds:
                        ConcurrentOutboxProbeTiming.timeoutNanoseconds,
                    pollingIntervalNanoseconds:
                        ConcurrentOutboxProbeTiming.pollingIntervalNanoseconds
                ) {
                    await backend.snapshot().signedEventCount
                        > baselineSignedEventCount
                }
                try Task.checkCancellation()
                guard wasSignaled else {
                    statusMessage = "并发探针等待超时，未修改交易状态"
                    return
                }

                // 扩展已提交后台事务但仍在 Debug 停顿中；主 App 此时从自己的
                // PaymentClient 实例并发重放，验证跨进程幂等和 outbox 状态合并。
                await backend.setFaultMode(.normal)
                let report = await client.retryUnfinishedTransactions()
                let finalBackendSnapshot = await backend.snapshot()
                try Task.checkCancellation()

                self.snapshot = report.snapshot
                self.backendSnapshot = finalBackendSnapshot
                self.errorMessage = nil
                self.statusMessage = report.snapshot.pendingTransactions.isEmpty
                    ? "并发探针完成：主 App 已重放并清理 outbox"
                    : "并发探针完成：仍有 \(report.snapshot.pendingTransactions.count) 笔待处理"
            } catch is CancellationError {
                // 取消或后台时间耗尽时，不再改变模拟后台和交易状态。
            } catch {
                statusMessage = "并发探针失败，交易仍保留在可靠 outbox"
            }
        }
    }

    /// 结束 Debug 并发探针持有的后台执行窗口。
    private func finishConcurrentOutboxProbe() {
        concurrentOutboxProbeTask = nil
        if concurrentOutboxBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(concurrentOutboxBackgroundTask)
            concurrentOutboxBackgroundTask = .invalid
        }
        isConcurrentOutboxProbeArmed = false
    }
#endif

#if os(iOS)
    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// 展示指定交易的系统退款请求界面。
    func requestRefund(for transaction: PaymentTransaction) async {
        await performStoreKitPresentation { [self] in
            guard let scene = activeWindowScene else {
                errorMessage = "当前没有可用于展示退款界面的 UIWindowScene"
                return
            }

            do {
                let outcome = try await PaymentPresentation.beginRefund(
                    for: transaction.id,
                    in: scene
                )
                statusMessage = outcome == .submitted ? "退款申请已提交" : "用户取消退款申请"
                await reconcileAfterStoreKitPresentation()
            } catch {
                present(error)
            }
        }
    }

    /// 展示 iOS 系统订阅管理界面。
    func showManageSubscriptions() async {
        await performStoreKitPresentation { [self] in
            guard let scene = activeWindowScene else {
                errorMessage = "当前没有可用于展示订阅管理的 UIWindowScene"
                return
            }

            do {
                let groupID = snapshot.products.compactMap(\.subscription?.groupID).first
                try await PaymentPresentation.showManageSubscriptions(
                    in: scene,
                    groupID: groupID
                )
                statusMessage = "订阅管理界面已关闭"
                await reconcileAfterStoreKitPresentation()
            } catch {
                present(error)
            }
        }
    }
#elseif os(macOS)
    /// 展示指定交易的系统退款请求界面。
    func requestRefund(for transaction: PaymentTransaction) async {
        await performStoreKitPresentation { [self] in
            guard let viewController = NSApplication.shared.keyWindow?.contentViewController else {
                errorMessage = "当前没有可用于展示退款界面的 NSViewController"
                return
            }

            do {
                let outcome = try await PaymentPresentation.beginRefund(
                    for: transaction.id,
                    in: viewController
                )
                statusMessage = outcome == .submitted ? "退款申请已提交" : "用户取消退款申请"
                await reconcileAfterStoreKitPresentation()
            } catch {
                present(error)
            }
        }
    }
#endif

    private func receive(_ intent: PaymentPurchaseIntent) {
        purchaseIntents.removeAll { $0.id == intent.id }
        purchaseIntents.append(intent)
        let suffix = intent.offer?.type == .winBack ? "（回归优惠）" : ""
        statusMessage = "收到 App Store 外部购买意图\(suffix)"
    }

    private func receive(_ event: PaymentEvent) async {
        let receiver = ExamplePaymentEventReceiver(
            updateSnapshot: { [weak self] in self?.snapshot = $0 },
            prependEvent: { [weak self] in self?.prependEvent($0) },
            updateTransactionStatus: { [weak self] transaction, finishState in
                self?.updateTransactionStatus(transaction, finishState: finishState)
            },
            reloadBackend: { [weak self] in
                await self?.reloadBackendSnapshot()
            }
        )
        await receiver.receive(event)
    }

    /// 使用签名事件顺序更新顶部脱敏交易状态。
    ///
    /// 自动续订、启动重放和直接购买统一经过该入口，避免旧交易异步完成后
    /// 覆盖较新的诊断结果。
    private func updateTransactionStatus(
        _ transaction: PaymentTransaction,
        finishState: PaymentFinishState
    ) {
        guard
            let message = transactionDiagnosticStatus.record(
                transaction,
                finishState: finishState
            )
        else {
            return
        }
        statusMessage = message
    }

    /// 在 StoreKit 系统界面关闭后协调可靠交付、商品状态和模拟后台快照。
    ///
    /// 此方法不会调用 `AppStore.sync()`；只有用户明确选择“恢复购买”时才允许同步。
    private func reconcileAfterStoreKitPresentation() async {
        let reconciler = StoreKitPresentationReconciler(
            reloadStoreSession: { [client] in
                await client.reloadStoreSession()
            },
            reloadBackend: { [weak self] in
                await self?.reloadBackendSnapshot()
            }
        )
        snapshot = await reconciler.reconcile()
        establishDefaultPurchaseSelections()
    }

    /// 串行展示 StoreKit 系统界面，并覆盖其返回后的状态协调阶段。
    private func performStoreKitPresentation(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        // 与购买、恢复等现有用户操作互斥，防止 MainActor 重入时错误清除忙碌状态。
        guard !isBusy else { return }
        _ = await storeKitPresentationSingleFlight.perform { [self] in
            isBusy = true
            defer { isBusy = false }
            await operation()
        }
    }

    private func prependEvent(_ message: String) {
        events.insert(message, at: 0)
        events = Array(events.prefix(20))
    }

    private func reloadBackendSnapshot() async {
        backendSnapshot = await backend.snapshot()
    }

    private func establishDefaultPurchaseSelections() {
        for product in snapshot.products {
            guard let subscription = product.subscription else { continue }
            if selectedBillingPlans[product.id] == nil {
                selectedBillingPlans[product.id] = subscription.pricingTerms.first?.billingPlan
            }
            if selectedOffers[product.id] == nil {
                selectedOffers[product.id] = defaultOffer(for: product)
            }
        }
    }

    private func defaultOffer(for product: PaymentProduct) -> ExampleOfferChoice {
        availableOffers(for: product).contains(.introductory)
            ? .introductory
            : .standard
    }

    func purchaseOptions(for product: PaymentProduct) throws -> PurchaseOptions {
        let offer: PaymentPurchaseOffer?
        switch selectedOffer(for: product) {
        case .standard:
            offer = nil
        case .introductory:
            offer = .introductory(eligibility: nil)
        case .promotional(let offerID):
            let compactJWS = promotionalAuthorizationJWS
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !compactJWS.isEmpty else {
                throw ExampleInputError.missingPromotionalAuthorization
            }
            offer = .promotional(
                authorization: PaymentPromotionalOfferAuthorization(
                    offerID: offerID,
                    compactJWS: compactJWS
                )
            )
        case .winBack(let offerID):
            offer = .winBack(offerID: offerID)
        case .sandboxOfferCode:
            throw ExampleInputError.offerCodeRequiresSystemRedemption
        }

        return PurchaseOptions(
            simulatesAskToBuyInSandbox: simulatesAskToBuy,
            billingPlan: selectedBillingPlan(for: product),
            offer: offer
        )
    }

    private func present(_ error: any Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        statusMessage = "操作失败，交易不会被错误地 finish"
    }
}

enum ExampleInputError: LocalizedError, Equatable {
    case missingPromotionalAuthorization
    case offerCodeRequiresSystemRedemption
    case sandboxOfferCodeRequiresYearlyProduct
    case sandboxOfferCodeUnavailable
    case sandboxOfferCodePresentationUnavailable
    case sandboxOfferCodePresentationFailed

    var errorDescription: String? {
        switch self {
        case .missingPromotionalAuthorization:
            "请粘贴开发签名工具或生产后台返回的促销优惠 compact JWS"
        case .offerCodeRequiresSystemRedemption:
            "Sandbox 优惠代码必须通过系统兑换页使用"
        case .sandboxOfferCodeRequiresYearlyProduct:
            "Sandbox 优惠代码仅适用于年订阅"
        case .sandboxOfferCodeUnavailable:
            "所选 Sandbox 优惠代码不可用"
        case .sandboxOfferCodePresentationUnavailable:
            "当前没有可用于展示 Sandbox 优惠代码兑换页的系统界面"
        case .sandboxOfferCodePresentationFailed:
            "Sandbox 优惠代码兑换失败，请稍后重试"
        }
    }
}
