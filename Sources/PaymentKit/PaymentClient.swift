import Dispatch
import Foundation
import StoreKit

private struct CachedSubscriptionStatusUpdate: Sendable {
    let status: PaymentSubscriptionStatus
    let renewalInfoSignedDate: Date?
}

private struct MappedStoreError {
    let error: PaymentError
    let metadata: [String: String]
}

/// 协调 StoreKit 商品、交易监听和可靠交付的支付客户端。
public actor PaymentClient {
    private static let maximumConcurrentTransactionUpdates = 4

    private let configuration: PaymentConfiguration
    private let processor: any TransactionProcessor
    private let gateway: any PaymentStoreGateway
    private let pendingStore: any PendingTransactionStore
    private let logger: any PaymentLogHandler
    private let applicationActivitySource: PaymentApplicationActivitySource
    private let automaticRefreshClock: PaymentAutomaticRefreshClock

    private var currentSnapshot = PaymentSnapshot.empty
    private var storeProducts: [String: StoreProduct] = [:]
    private var storeTransactions: [UInt64: StoreTransaction] = [:]
    private var processedTransactionStates = Set<PaymentTransactionDeliveryState>()
    private var awaitingFinishTransactionStates = Set<PaymentTransactionDeliveryState>()
    private var processingSignedEvents = Set<String>()
    private var processingTransactionStateEvents: [PaymentTransactionDeliveryState: String] = [:]
    private var processingSignedEventWaiters: [
        String: [UUID: CheckedContinuation<PaymentTransaction, any Error>]
    ] = [:]
    private var eventContinuations: [UUID: AsyncStream<PaymentEvent>.Continuation] = [:]
    private var purchaseIntentContinuations: [
        UUID: AsyncStream<PaymentPurchaseIntent>.Continuation
    ] = [:]
    private var storeMessageContinuations: [
        UUID: AsyncStream<PaymentStoreMessage>.Continuation
    ] = [:]
    private var pendingPurchaseIntents: [String: StorePurchaseIntent] = [:]
    private var updateTask: Task<Void, Never>?
    private var subscriptionStatusTask: Task<Void, Never>?
    private var purchaseIntentTask: Task<Void, Never>?
    private var storeMessageTask: Task<Void, Never>?
    private var storefrontTask: Task<Void, Never>?
    private var applicationActivityTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var stateBoundaryTask: Task<Void, Never>?
    private var stateBoundaryContext: PaymentAutomaticRefreshBoundaryContext?
    private var exhaustedStateBoundaryTargets: [
        PaymentAutomaticRefreshBoundaryState
    ] = []
    private var pendingAutomaticRefreshStrength: PaymentAutomaticRefreshStrength?
    private var pendingAutomaticRefreshReplaysUnfinishedTransactions = false
    private var pendingAutomaticRefreshBoundaryContext:
        PaymentAutomaticRefreshBoundaryContext?
    private var cachedSubscriptionStatusUpdates: [
        String: CachedSubscriptionStatusUpdate
    ] = [:]
    private var authoritativeSubscriptionStatusGroupIDs = Set<String>()
    private var lastSubscriptionStatusUpdate: StoreSubscriptionStatusResult?
    private var explicitStoreSyncDepth = 0
    private var isStoreMessageConsumptionRequested = false
    private var purchaseIntentsSupported: Bool?
    private var storeMessagesSupported: Bool?
    private var startupTask: Task<Void, Never>?
    private var isStarted = false
    private var lifecycleGeneration: UInt64 = 0
    private var productLoadRequestID: UInt64 = 0
    private var committedProductLoadRequestID: UInt64 = 0
    private var stateRefreshRequestID: UInt64 = 0
    private var committedStateRefreshRequestID: UInt64 = 0

    /// 创建支付客户端。
    ///
    /// - Parameters:
    ///   - configuration: 需要加载的商品配置。
    ///   - processor: 负责后台验签和幂等交付的交易处理器。
    ///   - logger: 结构化日志处理器，默认写入统一日志系统。
    public init(
        configuration: PaymentConfiguration,
        processor: any TransactionProcessor,
        logger: any PaymentLogHandler = OSPaymentLogHandler()
    ) {
        self.configuration = configuration
        self.processor = processor
        gateway = StoreKitPaymentStoreGateway(logger: logger)
        let databaseURL = PaymentStorageConfiguration
            .applicationContainerDatabaseURL()
        pendingStore = SQLitePendingTransactionStore(
            databaseURL: databaseURL,
            logger: logger
        )
        self.logger = logger
        applicationActivitySource = .system
        automaticRefreshClock = PaymentAutomaticRefreshClock()
    }

    /// 创建使用显式存储位置的支付客户端。
    ///
    /// App Group 配置会在初始化期间验证共享容器是否可访问。验证失败时立即抛错，
    /// 不会静默回退到应用容器。
    ///
    /// - Parameters:
    ///   - configuration: 需要加载的商品配置。
    ///   - processor: 负责后台验签和幂等交付的交易处理器。
    ///   - storage: 应用容器或 App Group 存储配置。
    ///   - logger: 结构化日志处理器，默认写入统一日志系统。
    /// - Throws: App Group 配置无效或容器不可访问时抛出 `PaymentError`。
    public init(
        configuration: PaymentConfiguration,
        processor: any TransactionProcessor,
        storage: PaymentStorageConfiguration,
        logger: any PaymentLogHandler = OSPaymentLogHandler()
    ) throws {
        let databaseURL = try storage.databaseURL()
        self.configuration = configuration
        self.processor = processor
        gateway = StoreKitPaymentStoreGateway(logger: logger)
        pendingStore = SQLitePendingTransactionStore(
            databaseURL: databaseURL,
            logger: logger
        )
        self.logger = logger
        applicationActivitySource = .system
        automaticRefreshClock = PaymentAutomaticRefreshClock()
    }

    /// 创建使用隔离 SQLite outbox 的支付客户端。
    ///
    /// 此入口仅供集成测试使用，使每个 StoreKit 测试会话拥有独立的待交付交易数据库。
    /// 生产代码应使用标准初始化方法，让同一进程内的客户端共享默认存储。
    ///
    /// - Parameters:
    ///   - configuration: 需要加载的商品配置。
    ///   - processor: 负责后台验签和幂等交付的交易处理器。
    ///   - logger: 结构化日志处理器。
    ///   - pendingTransactionsDatabaseURL: 当前测试专用的 SQLite 地址。
    @_spi(Testing)
    public init(
        configuration: PaymentConfiguration,
        processor: any TransactionProcessor,
        logger: any PaymentLogHandler = DisabledPaymentLogHandler(),
        pendingTransactionsDatabaseURL: URL
    ) {
        self.configuration = configuration
        self.processor = processor
        gateway = StoreKitPaymentStoreGateway(logger: logger)
        pendingStore = SQLitePendingTransactionStore(
            databaseURL: pendingTransactionsDatabaseURL,
            logger: logger
        )
        self.logger = logger
        applicationActivitySource = .system
        automaticRefreshClock = PaymentAutomaticRefreshClock()
    }

    /// 创建使用自定义 StoreKit 网关的支付客户端。
    ///
    /// 此初始化方法仅供包内测试和 StoreKit 适配层使用。
    internal init(
        configuration: PaymentConfiguration,
        processor: any TransactionProcessor,
        gateway: any PaymentStoreGateway,
        pendingStore: any PendingTransactionStore = InMemoryPendingTransactionStore(),
        logger: any PaymentLogHandler,
        applicationActivitySource: PaymentApplicationActivitySource = .system,
        automaticRefreshClock: PaymentAutomaticRefreshClock = .init()
    ) {
        self.configuration = configuration
        self.processor = processor
        self.gateway = gateway
        self.pendingStore = pendingStore
        self.logger = logger
        self.applicationActivitySource = applicationActivitySource
        self.automaticRefreshClock = automaticRefreshClock
    }

    deinit {
        updateTask?.cancel()
        subscriptionStatusTask?.cancel()
        purchaseIntentTask?.cancel()
        storeMessageTask?.cancel()
        storefrontTask?.cancel()
        applicationActivityTask?.cancel()
        automaticRefreshTask?.cancel()
        stateBoundaryTask?.cancel()
        startupTask?.cancel()
    }

    /// 启动交易监听并加载初始状态。
    ///
    /// 可以安全地重复调用。客户端会先建立 `Transaction.updates` 监听，再处理未完成交易，
    /// 避免在商品加载期间遗漏外部完成的交易。
    public func start() async {
        guard !isStarted else {
            log(.debug, category: "lifecycle", message: "忽略重复启动")
            return
        }
        isStarted = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration

        // 监听必须先于任何可能挂起的加载工作建立，确保启动窗口内的交易不会遗漏。
        let updates = await gateway.transactionUpdates()
        guard isCurrentLifecycle(generation) else {
            // transactionUpdates() 可能挂起；停止或重新启动后，旧调用不能覆盖新监听任务。
            log(.debug, category: "lifecycle", message: "忽略过期的启动任务")
            return
        }
        let updateClientReference = WeakPaymentClientReference(self)
        let updateGateway = gateway
        updateTask = Task {
            await Self.listenForTransactionUpdates(
                initialUpdates: updates,
                gateway: updateGateway,
                clientReference: updateClientReference,
                generation: generation
            )
        }
        let subscriptionStatusUpdates = await gateway.subscriptionStatusUpdates()
        guard isCurrentLifecycle(generation) else {
            log(.debug, category: "lifecycle", message: "忽略过期的订阅状态监听")
            return
        }
        let subscriptionStatusClientReference = WeakPaymentClientReference(self)
        let subscriptionStatusGateway = gateway
        subscriptionStatusTask = Task {
            await Self.listenForSubscriptionStatusUpdates(
                subscriptionStatusUpdates,
                gateway: subscriptionStatusGateway,
                clientReference: subscriptionStatusClientReference,
                generation: generation
            )
        }
        let storefrontUpdates = await gateway.storefrontUpdates()
        guard isCurrentLifecycle(generation) else {
            log(.debug, category: "lifecycle", message: "忽略过期的 Storefront 监听")
            return
        }
        let storefrontClientReference = WeakPaymentClientReference(self)
        let storefrontGateway = gateway
        storefrontTask = Task {
            await Self.listenForStorefrontUpdates(
                storefrontUpdates,
                gateway: storefrontGateway,
                clientReference: storefrontClientReference,
                generation: generation
            )
        }
        let applicationActivityEvents = await applicationActivitySource.events()
        guard isCurrentLifecycle(generation) else {
            log(.debug, category: "lifecycle", message: "忽略过期的应用活动监听")
            return
        }
        let activityClientReference = WeakPaymentClientReference(self)
        applicationActivityTask = Task {
            await Self.listenForApplicationActivity(
                applicationActivityEvents,
                clientReference: activityClientReference,
                generation: generation
            )
        }
        let supportsPurchaseIntents = await gateway.supportsPurchaseIntents()
        guard isCurrentLifecycle(generation) else {
            log(.debug, category: "lifecycle", message: "忽略过期的购买意图能力检查")
            return
        }
        purchaseIntentsSupported = supportsPurchaseIntents
        if supportsPurchaseIntents {
            let purchaseIntents = await gateway.purchaseIntents()
            guard isCurrentLifecycle(generation) else {
                log(.debug, category: "lifecycle", message: "忽略过期的购买意图监听")
                return
            }
            let purchaseIntentClientReference = WeakPaymentClientReference(self)
            let purchaseIntentGateway = gateway
            purchaseIntentTask = Task {
                await Self.listenForPurchaseIntents(
                    purchaseIntents,
                    gateway: purchaseIntentGateway,
                    clientReference: purchaseIntentClientReference,
                    generation: generation
                )
            }
        } else {
            // 不支持的系统必须正常结束公开流，不能让界面永久等待首个元素。
            finishPurchaseIntentContinuations()
        }
        if isStoreMessageConsumptionRequested {
            startStoreMessageListener(generation: generation)
        }
        log(.info, category: "lifecycle", message: "支付客户端已启动")

        // 启动重放属于客户端生命周期；stop() 必须能够取消处理器和后续 finish。
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performInitialStartup(generation: generation)
        }
        startupTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if isCurrentLifecycle(generation) {
            startupTask = nil
        }
    }

    /// 停止交易监听。
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        lifecycleGeneration &+= 1
        updateTask?.cancel()
        updateTask = nil
        subscriptionStatusTask?.cancel()
        subscriptionStatusTask = nil
        purchaseIntentTask?.cancel()
        purchaseIntentTask = nil
        storeMessageTask?.cancel()
        storeMessageTask = nil
        storefrontTask?.cancel()
        storefrontTask = nil
        applicationActivityTask?.cancel()
        applicationActivityTask = nil
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        stateBoundaryTask?.cancel()
        stateBoundaryTask = nil
        stateBoundaryContext = nil
        exhaustedStateBoundaryTargets.removeAll()
        pendingAutomaticRefreshStrength = nil
        pendingAutomaticRefreshReplaysUnfinishedTransactions = false
        pendingAutomaticRefreshBoundaryContext = nil
        cachedSubscriptionStatusUpdates.removeAll()
        authoritativeSubscriptionStatusGroupIDs.removeAll()
        lastSubscriptionStatusUpdate = nil
        storeTransactions.removeAll()
        startupTask?.cancel()
        startupTask = nil
        pendingPurchaseIntents.removeAll()
        log(.info, category: "lifecycle", message: "支付客户端已停止")
    }

    /// 在不退出进程的情况下重建当前 StoreKit 会话。
    ///
    /// Apple 账户可能在 App 外部发生切换，StoreKit 没有提供公开的账户切换通知。
    /// 调用此方法会停止并重建 StoreKit 异步序列，清除上一会话的订阅状态事件缓存，
    /// 然后重新加载商品、权益、订阅状态和未完成交易。
    ///
    /// 现有已验证快照会保留到新会话成功提交状态，因此弱网或离线重载不会把暂时
    /// 不可用误判为权益消失。可靠交付 outbox 也不会被清除。
    ///
    /// 此方法不会调用 `AppStore.sync()`，不会主动显示 Apple 账户认证界面。应用可在
    /// 已知 StoreKit 系统流程返回后调用，但不能依赖它识别完全发生在 App 外的账户
    /// 切换；该场景必须由用户明确调用 `restorePurchases()`。不应在每次进入前台时
    /// 无条件调用本方法。
    ///
    /// - Returns: 新会话完成初始加载后客户端持有的最新快照。
    @discardableResult
    public func reloadStoreSession() async -> PaymentSnapshot {
        stop()
        await start()
        return currentSnapshot
    }

    /// 请求一次受当前客户端生命周期约束的自动刷新。
    ///
    /// 首个请求会等待短暂合并窗口；完整刷新会覆盖同一批次中的轻量刷新。
    /// 刷新期间到达的新请求保留到当前轮结束后执行。
    ///
    /// - Parameters:
    ///   - strength: 需要刷新的状态范围。
    ///   - reason: 仅用于结构化日志的固定触发原因。
    ///   - generation: 发起请求的客户端生命周期编号。
    ///   - stateBoundaryContext: 边界触发携带的有限收敛上下文。
    func requestAutomaticRefresh(
        _ strength: PaymentAutomaticRefreshStrength,
        reason: String,
        generation: UInt64,
        replaysUnfinishedTransactions: Bool = false,
        stateBoundaryContext: PaymentAutomaticRefreshBoundaryContext? = nil
    ) {
        guard isCurrentLifecycle(generation) else { return }
        guard explicitStoreSyncDepth == 0 || reason != "application-active" else {
            // AppStore.sync() 的系统认证页会切换应用活动状态。认证完成前 StoreKit
            // 可能短暂返回空权益；成功路径随后会主动完整刷新，失败路径应保留旧快照。
            log(
                .debug,
                category: "automatic-refresh",
                message: "恢复认证期间忽略应用激活刷新"
            )
            return
        }
        pendingAutomaticRefreshStrength = pendingAutomaticRefreshStrength
            .map { $0.merging(strength) } ?? strength
        pendingAutomaticRefreshReplaysUnfinishedTransactions =
            pendingAutomaticRefreshReplaysUnfinishedTransactions
                || replaysUnfinishedTransactions
        if let stateBoundaryContext {
            pendingAutomaticRefreshBoundaryContext = stateBoundaryContext
        }
        log(
            .debug,
            category: "automatic-refresh",
            message: "已接收自动刷新请求",
            metadata: [
                "reason": reason,
                "strength": strength.logName,
            ]
        )
        guard automaticRefreshTask == nil else { return }

        automaticRefreshTask = Task { [weak self] in
            await self?.runAutomaticRefreshTask(generation: generation)
        }
    }

    /// 使用最新快照重新安排下一次订阅时间边界刷新。
    ///
    /// 新快照始终先取消旧任务。睡眠任务只持有客户端弱引用，避免未来边界保活客户端。
    ///
    /// - Parameters:
    ///   - snapshot: 刚刚成功提交的支付快照。
    ///   - generation: 拥有该快照的客户端生命周期编号。
    func scheduleNextStateBoundary(
        from snapshot: PaymentSnapshot,
        generation: UInt64
    ) {
        guard isCurrentLifecycle(generation) else { return }
        stateBoundaryTask?.cancel()
        stateBoundaryTask = nil

        let now = automaticRefreshClock.now()
        let currentTargets = PaymentAutomaticRefreshDeadline.targets(in: snapshot)
        exhaustedStateBoundaryTargets.removeAll { target in
            !currentTargets.contains(target)
        }
        if let target = PaymentAutomaticRefreshDeadline.unconvergedTarget(
            in: snapshot,
            at: now,
            excluding: exhaustedStateBoundaryTargets
        ) {
            let delays = PaymentAutomaticRefreshBoundaryRetry.delays
            if let context = stateBoundaryContext,
               context.target == target {
                if context.nextRetryDelayIndex > 0 {
                    let delayIndex = context.nextRetryDelayIndex - 1
                    scheduleStateBoundarySleep(
                        at: now.addingTimeInterval(delays[delayIndex]),
                        context: context,
                        generation: generation
                    )
                    return
                }
            }
            scheduleStateBoundarySleep(
                at: now.addingTimeInterval(delays[0]),
                context: PaymentAutomaticRefreshBoundaryContext(
                    target: target,
                    nextRetryDelayIndex: 1
                ),
                generation: generation
            )
            return
        }
        guard let target = PaymentAutomaticRefreshDeadline.nextTarget(
            in: snapshot,
            after: now
        ) else {
            stateBoundaryContext = nil
            return
        }
        scheduleStateBoundarySleep(
            at: target.key.date,
            context: PaymentAutomaticRefreshBoundaryContext(
                target: target,
                nextRetryDelayIndex: 0
            ),
            generation: generation
        )
    }

    /// 返回当前只读状态快照。
    public func snapshot() -> PaymentSnapshot {
        currentSnapshot
    }

    /// 从 App Store 重新加载商品。
    ///
    /// StoreKit 没有返回的标识符会记录到 `PaymentSnapshot.unavailableProductIDs`，
    /// 其余有效商品仍会正常返回。
    ///
    /// - Returns: 按配置顺序排列的有效商品。
    /// - Throws: StoreKit 无法完成商品请求时产生的错误。
    @discardableResult
    public func reloadProducts() async throws -> [PaymentProduct] {
        try await performReloadProducts(requiredLifecycleGeneration: nil)
    }

    /// 为生命周期拥有的刷新加载商品；生命周期变化后不得提交旧响应。
    @discardableResult
    internal func reloadProducts(
        requiredLifecycleGeneration: UInt64
    ) async throws -> [PaymentProduct] {
        try await performReloadProducts(
            requiredLifecycleGeneration: requiredLifecycleGeneration
        )
    }

    private func performReloadProducts(
        requiredLifecycleGeneration: UInt64?
    ) async throws -> [PaymentProduct] {
        productLoadRequestID &+= 1
        let requestID = productLoadRequestID
        log(
            .info,
            category: "products",
            message: "开始加载商品",
            metadata: ["requestedCount": "\(configuration.productIDs.count)"]
        )

        let loaded: [StoreProduct]
        do {
            loaded = try await gateway.loadProducts(for: configuration.productIDs)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log(.error, category: "products", message: "商品加载失败")
            throw mapStoreError(error, operation: "加载商品")
        }

        let loadedByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.value.id, $0) })
        let ordered = configuration.productIDs.compactMap { loadedByID[$0] }
        let missing = configuration.productIDs.filter { loadedByID[$0] == nil }
        let canMakePayments = await gateway.canMakePayments()
        try Task.checkCancellation()
        try checkRequiredLifecycle(requiredLifecycleGeneration)

        // 只有较新的成功提交才能淘汰旧响应；较晚请求失败时，旧成功结果仍应进入缓存。
        guard requestID > committedProductLoadRequestID else {
            return ordered.map(\.value)
        }
        committedProductLoadRequestID = requestID
        storeProducts = loadedByID

        currentSnapshot = PaymentSnapshot(
            canMakePayments: canMakePayments,
            products: ordered.map(\.value),
            unavailableProductIDs: missing,
            currentEntitlements: currentSnapshot.currentEntitlements,
            subscriptionStatuses: currentSnapshot.subscriptionStatuses,
            pendingTransactions: currentSnapshot.pendingTransactions
        )
        emit(.snapshotUpdated(currentSnapshot))
        log(
            missing.isEmpty ? .info : .warning,
            category: "products",
            message: "商品加载完成",
            metadata: [
                "loadedCount": "\(ordered.count)",
                "unavailableCount": "\(missing.count)",
            ]
        )
        return ordered.map(\.value)
    }

    /// 刷新商品、当前权益、订阅状态和未完成交易。
    ///
    /// - Returns: 刷新后的完整状态快照。
    /// - Throws: 商品加载失败时产生的错误。单条权益或订阅验签失败会通过事件报告，
    ///   不会使其余已验证状态丢失。
    @discardableResult
    public func refresh() async throws -> PaymentSnapshot {
        try await performRefresh(requiredLifecycleGeneration: nil)
    }

    /// 为生命周期拥有的自动刷新执行完整加载；停止后不得提交旧响应。
    @discardableResult
    internal func refresh(
        requiredLifecycleGeneration: UInt64,
        stateBoundaryContext: PaymentAutomaticRefreshBoundaryContext? = nil
    ) async throws -> PaymentSnapshot {
        try await performRefresh(
            requiredLifecycleGeneration: requiredLifecycleGeneration,
            stateBoundaryContext: stateBoundaryContext
        )
    }

    private func performRefresh(
        requiredLifecycleGeneration: UInt64?,
        stateBoundaryContext: PaymentAutomaticRefreshBoundaryContext? = nil
    ) async throws -> PaymentSnapshot {
        stateRefreshRequestID &+= 1
        let requestID = stateRefreshRequestID
        if let requiredLifecycleGeneration {
            _ = try await reloadProducts(
                requiredLifecycleGeneration: requiredLifecycleGeneration
            )
        } else {
            _ = try await reloadProducts()
        }

        while true {
            let productVersion = committedProductLoadRequestID
            let groupIDs = Set(
                currentSnapshot.products.compactMap { $0.subscription?.groupID }
            )
            let entitlementResults = await gateway.currentEntitlements()
            let storeUnfinishedResults = await gateway.unfinishedTransactions()
            let unfinishedResults = await recoverPersistedTransactions(
                including: storeUnfinishedResults
            ).verifications
            let queriedSubscriptionResult = await gateway.subscriptionStatuses(
                for: groupIDs
            )
            let transactionCheckedSubscriptionResult =
                await crossCheckSubscriptionStatusesByTransactionID(
                    queriedSubscriptionResult
                )
            let subscriptionResult = reconcileSubscriptionStatusResult(
                transactionCheckedSubscriptionResult,
                requestedGroupIDs: groupIDs
            )
            let canMakePayments = await gateway.canMakePayments()
            try Task.checkCancellation()

            // 商品在查询期间变化时重新汇总，避免旧订阅组结果覆盖新商品状态。
            guard productVersion == committedProductLoadRequestID else { continue }

            let entitlements = verifiedTransactions(from: entitlementResults)
            let pending = try await reconcilePendingTransactions(
                from: unfinishedResults,
                requiredLifecycleGeneration: requiredLifecycleGeneration
            )
            try checkRequiredLifecycle(requiredLifecycleGeneration)
            for failure in subscriptionResult.verificationFailures {
                reportVerificationFailure(
                    transactionID: failure.transactionID,
                    message: failure.message
                )
            }

            // actor 在每个 await 处允许重入；仅晚于上次成功提交的响应可以更新状态。
            guard requestID > committedStateRefreshRequestID else {
                return currentSnapshot
            }
            committedStateRefreshRequestID = requestID

            currentSnapshot = PaymentSnapshot(
                canMakePayments: canMakePayments,
                products: currentSnapshot.products,
                unavailableProductIDs: currentSnapshot.unavailableProductIDs,
                currentEntitlements: entitlements,
                subscriptionStatuses: subscriptionResult.statuses,
                pendingTransactions: pending
            )
            emit(.snapshotUpdated(currentSnapshot))
            scheduleStateBoundaryAfterSnapshotCommit(
                currentSnapshot,
                requiredLifecycleGeneration: requiredLifecycleGeneration,
                stateBoundaryContext: stateBoundaryContext
            )
            log(
                .info,
                category: "state",
                message: "支付状态刷新完成",
                metadata: [
                    "entitlementCount": "\(entitlements.count)",
                    "subscriptionCount": "\(subscriptionResult.statuses.count)",
                    "pendingCount": "\(pending.count)",
                ]
            )
            return currentSnapshot
        }
    }

    /// 购买指定商品。
    ///
    /// - Parameters:
    ///   - productID: 已通过 `reloadProducts()` 加载的商品标识符。
    ///   - options: 数量、应用账户令牌和 sandbox 购买选项。
    /// - Returns: 完成、待批准或用户取消状态。
    /// - Throws: 商品不存在、支付受限、StoreKit 失败、验签失败或后台处理失败时产生的错误。
    public func purchase(
        productID: String,
        options: PurchaseOptions = .init()
    ) async throws -> PurchaseOutcome {
        try await performPurchase(
            productID: productID,
            options: options,
            allowedExternalWinBackOfferID: nil
        )
    }

    /// 完成用户从 App Store 或系统回归优惠入口发起的购买意图。
    ///
    /// - Parameters:
    ///   - intent: 当前客户端通过 `purchaseIntents()` 产生的购买意图。
    ///   - options: 应用账户令牌、数量和可选账单计划。
    /// - Returns: 完成、待批准或用户取消状态。
    public func purchase(
        intent: PaymentPurchaseIntent,
        options: PurchaseOptions = .init()
    ) async throws -> PurchaseOutcome {
        guard let storedIntent = pendingPurchaseIntents[intent.id],
              storedIntent.value == intent else {
            throw PaymentError(
                code: .invalidPurchaseOptions,
                message: "购买意图不属于当前客户端或已经处理",
                productID: intent.productID
            )
        }

        var selectedOffer = options.offer
        var allowedWinBackOfferID: String?
        if let intentOffer = intent.offer {
            guard intentOffer.type == .winBack, let offerID = intentOffer.id else {
                throw PaymentError(
                    code: .invalidPurchaseOptions,
                    message: "系统购买意图包含无法处理的优惠",
                    productID: intent.productID
                )
            }
            let intentSelection = PaymentPurchaseOffer.winBack(offerID: offerID)
            if let selectedOffer, selectedOffer != intentSelection {
                throw PaymentError(
                    code: .invalidPurchaseOptions,
                    message: "购买意图优惠不能被其他优惠替换",
                    productID: intent.productID
                )
            }
            selectedOffer = intentSelection
            allowedWinBackOfferID = offerID
        }

        storeProducts[intent.productID] = storedIntent.product
        let resolvedOptions = PurchaseOptions(
            quantity: options.quantity,
            appAccountToken: options.appAccountToken,
            simulatesAskToBuyInSandbox: options.simulatesAskToBuyInSandbox,
            billingPlan: options.billingPlan,
            offer: selectedOffer
        )
        let outcome = try await performPurchase(
            productID: intent.productID,
            options: resolvedOptions,
            allowedExternalWinBackOfferID: allowedWinBackOfferID,
            storeIntent: storedIntent
        )
        pendingPurchaseIntents[intent.id] = nil
        return outcome
    }

    /// 执行普通购买或已验证来源的外部购买意图。
    private func performPurchase(
        productID: String,
        options: PurchaseOptions,
        allowedExternalWinBackOfferID: String?,
        storeIntent: StorePurchaseIntent? = nil
    ) async throws -> PurchaseOutcome {
        guard options.quantity > 0 else {
            throw PaymentError(
                code: .invalidQuantity,
                message: "购买数量必须大于 0",
                productID: productID
            )
        }
        guard let storeProduct = storeProducts[productID] else {
            throw PaymentError(
                code: .productNotFound,
                message: "商品尚未加载或不可用：\(productID)",
                productID: productID
            )
        }
        try validatePurchaseOptions(
            options,
            for: storeProduct.value,
            allowedExternalWinBackOfferID: allowedExternalWinBackOfferID
        )
        guard await gateway.canMakePayments() else {
            throw PaymentError(
                code: .purchasesNotAllowed,
                message: "当前设备不允许进行 App Store 购买",
                productID: productID
            )
        }

        log(
            .info,
            category: "purchase",
            message: "开始购买",
            metadata: ["productID": productID, "quantity": "\(options.quantity)"]
        )

        let result: StorePurchaseResult
        do {
            if let storeIntent {
                result = try await gateway.purchase(intent: storeIntent, options: options)
            } else {
                result = try await gateway.purchase(productID: productID, options: options)
            }
        } catch let error as PaymentError {
            log(.error, category: "purchase", message: "购买失败", metadata: ["productID": productID])
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log(.error, category: "purchase", message: "购买失败", metadata: ["productID": productID])
            throw mapStoreError(error, operation: "购买商品", productID: productID)
        }

        switch result {
        case .pending:
            emit(.purchasePending(productID: productID))
            log(.info, category: "purchase", message: "购买等待批准", metadata: ["productID": productID])
            return .pending
        case .userCancelled:
            log(.info, category: "purchase", message: "用户取消购买", metadata: ["productID": productID])
            return .cancelled
        case .success(let verification):
            let transaction = try await process(verification)
            // 自动续期首购会改变整个订阅组资格；交付成功后重新加载商品，
            // 再汇总权益，确保购买返回时商品和交易状态来自同一账户历史。
            _ = await refreshAfterProcessedTransactions([transaction])
            return .completed(transaction)
        }
    }

    /// 校验购买账单计划和优惠是否适用于目标商品。
    ///
    /// 此处只校验本机已有商品元数据和 compact JWS 外形。生产后台负责业务资格，
    /// StoreKit 负责最终验证 Apple 账户、签名及 storefront 条件。
    private func validatePurchaseOptions(
        _ options: PurchaseOptions,
        for product: PaymentProduct,
        allowedExternalWinBackOfferID: String?
    ) throws {
        if let billingPlan = options.billingPlan {
            guard product.type == .autoRenewableSubscription,
                  let subscription = product.subscription,
                  billingPlan.isKnown,
                  subscription.pricingTerms.contains(where: {
                      $0.billingPlan == billingPlan
                  }) else {
                throw PaymentError(
                    code: .billingPlanUnavailable,
                    message: "目标商品不支持请求的账单计划",
                    productID: product.id
                )
            }
        }

        guard let offer = options.offer else { return }
        guard product.type == .autoRenewableSubscription,
              let subscription = product.subscription else {
            let code: PaymentErrorCode
            if case .introductory(let eligibility) = offer, eligibility != nil {
                code = .invalidPurchaseOptions
            } else {
                code = .offerNotFound
            }
            throw PaymentError(
                code: code,
                message: "目标商品不支持订阅优惠",
                productID: product.id
            )
        }

        switch offer {
        case .introductory(let eligibility):
            guard subscription.introductoryOffer != nil else {
                throw PaymentError(
                    code: eligibility == nil ? .offerNotFound : .invalidPurchaseOptions,
                    message: "目标商品没有配置首购优惠",
                    productID: product.id
                )
            }
            if let eligibility {
                try validateCompactJWS(
                    eligibility.compactJWS,
                    code: .invalidPurchaseOptions,
                    message: "首购优惠资格声明格式无效",
                    productID: product.id
                )
            } else if !subscription.isEligibleForIntroductoryOffer {
                throw PaymentError(
                    code: .offerNotEligible,
                    message: "当前账户不符合首购优惠资格",
                    productID: product.id
                )
            }

        case .promotional(let authorization):
            guard subscription.promotionalOffers.contains(where: {
                $0.id == authorization.offerID && $0.type == .promotional
            }) else {
                throw PaymentError(
                    code: .offerNotFound,
                    message: "目标商品没有配置请求的促销优惠",
                    productID: product.id
                )
            }
            try validateCompactJWS(
                authorization.compactJWS,
                code: .offerAuthorizationInvalid,
                message: "促销优惠授权格式无效",
                productID: product.id
            )

        case .winBack(let offerID):
            guard subscription.winBackOffers.contains(where: {
                $0.id == offerID && $0.type == .winBack
            }) else {
                throw PaymentError(
                    code: .offerNotFound,
                    message: "目标商品没有配置请求的回归优惠",
                    productID: product.id
                )
            }
            let isEligible = currentSnapshot.subscriptionStatuses.contains { status in
                status.groupID == subscription.groupID
                    && status.renewalInfo.eligibleWinBackOfferIDs.contains(offerID)
            }
            guard isEligible || allowedExternalWinBackOfferID == offerID else {
                throw PaymentError(
                    code: .offerNotEligible,
                    message: "当前账户不符合回归优惠资格",
                    productID: product.id
                )
            }
        }

        if let billingPlan = options.billingPlan {
            let termOffers = subscription.pricingTerms
                .first(where: { $0.billingPlan == billingPlan })?
                .offers ?? []
            let selectedID: String?
            let selectedType: PaymentOfferType
            switch offer {
            case .introductory:
                selectedID = subscription.introductoryOffer?.id
                selectedType = .introductory
            case .promotional(let authorization):
                selectedID = authorization.offerID
                selectedType = .promotional
            case .winBack(let offerID):
                selectedID = offerID
                selectedType = .winBack
            }
            guard termOffers.contains(where: {
                $0.type == selectedType
                    && ($0.id == selectedID || ($0.id == nil && selectedID == nil))
            }) else {
                throw PaymentError(
                    code: .offerNotFound,
                    message: "请求的优惠不适用于所选账单计划",
                    productID: product.id
                )
            }
        }
    }

    /// 校验 compact JWS 由三个非空段组成，且不在错误中回显敏感内容。
    private func validateCompactJWS(
        _ compactJWS: String,
        code: PaymentErrorCode,
        message: String,
        productID: String
    ) throws {
        let segments = compactJWS.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else {
            throw PaymentError(
                code: code,
                message: message,
                productID: productID
            )
        }
    }

    /// 由用户主动触发 App Store 购买恢复。
    ///
    /// 此方法会显示系统认证界面，因此不应在应用启动时自动调用。
    ///
    /// 同步成功后会清除上一 StoreKit 会话的订阅事件与原始交易缓存，并重建长期
    /// 监听。这样用户在 App 外切换 Apple 账户后，无需结束进程也能让新账户状态
    /// 替换旧账户状态。同步失败时不会停止现有会话，也不会清除最后有效快照。
    ///
    /// - Returns: 同步、会话重建、重试和刷新后的状态快照。
    /// - Throws: App Store 同步或状态刷新失败时产生的错误。
    @discardableResult
    public func restorePurchases() async throws -> PaymentSnapshot {
        log(.info, category: "restore", message: "开始恢复购买")
        do {
            try await synchronizeStoreForExplicitRestore()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = mapStoreFailure(error, operation: "恢复购买")
            log(
                .error,
                category: "restore",
                message: "恢复购买同步失败",
                metadata: failure.metadata
            )
            throw failure.error
        }

        // AppStore.sync() 是 Apple 提供的显式账户/交易重新同步边界。同步成功后必须
        // 丢弃旧会话的长期序列和权威订阅事件缓存；只在旧会话上 refresh 会继续
        // 合并上一账户的状态。start() 会先重建监听，再重放 unfinished/outbox。
        stop()
        await start()
        let restoredGeneration = lifecycleGeneration
        try Task.checkCancellation()
        guard isCurrentLifecycle(restoredGeneration) else {
            throw CancellationError()
        }
        let snapshot = try await refresh(
            requiredLifecycleGeneration: restoredGeneration
        )
        emit(.restoreCompleted(snapshot))
        log(.info, category: "restore", message: "恢复购买完成")
        return snapshot
    }

    /// 执行一次用户明确发起的 App Store 同步。
    ///
    /// 同步认证系统页产生的应用激活通知不能在认证结束前提交瞬时空权益。深度计数
    /// 同时覆盖多个重入调用，确保任一同步仍在等待时继续抑制这类通知。
    private func synchronizeStoreForExplicitRestore() async throws {
        explicitStoreSyncDepth += 1
        defer { explicitStoreSyncDepth -= 1 }
        try await gateway.sync()
    }

    /// 重试所有未完成交易。
    ///
    /// 除了 StoreKit 当前返回的未完成交易，还会从框架持久记录中找回上次处理失败、
    /// 但新进程未通过 `Transaction.unfinished` 收到的交易。
    /// 验签或后台处理失败的交易不会结束，后续调用仍可再次尝试。
    @discardableResult
    public func retryUnfinishedTransactions() async -> PaymentRetryReport {
        let unfinished = await gateway.unfinishedTransactions()
        return await retryUnfinishedTransactions(
            including: unfinished,
            requiredLifecycleGeneration: nil,
            refreshStateAfterProcessing: true
        )
    }

    /// 处理一批已经取得的 unfinished 交易。
    ///
    /// 前台恢复路径先取得一次 StoreKit 快照并在同一自动刷新批次内重放，避免
    /// 账号切换后只把 newly-discovered unfinished 显示为待处理，却要等到冷启动
    /// 或用户手动重试才进入可靠 outbox。
    private func retryUnfinishedTransactions(
        including unfinished: [StoreTransactionVerification],
        requiredLifecycleGeneration: UInt64?,
        refreshStateAfterProcessing: Bool
    ) async -> PaymentRetryReport {
        let recovery = await recoverPersistedTransactions(including: unfinished)
        let transactions = recovery.verifications
        guard !transactions.isEmpty else {
            let snapshot = refreshStateAfterProcessing
                ? await refreshStateWithoutReloadingProducts(
                    requiredLifecycleGeneration: requiredLifecycleGeneration
                )
                : currentSnapshot
            return PaymentRetryReport(
                attemptedCount: 0,
                deliveredCount: 0,
                finishedCount: 0,
                awaitingFinishCount: 0,
                failureCount: 0,
                unresolvedCount: recovery.unresolvedCount,
                snapshot: snapshot
            )
        }

        log(
            .info,
            category: "transactions",
            message: "开始重试未完成交易",
            metadata: ["count": "\(transactions.count)"]
        )
        var attemptedCount = 0
        var deliveredCount = 0
        var finishedCount = 0
        var awaitingFinishCount = 0
        var failureCount = 0
        var processedTransactions: [PaymentTransaction] = []
        for verification in transactions {
            guard !Task.isCancelled else { break }
            do {
                try checkRequiredLifecycle(requiredLifecycleGeneration)
            } catch {
                break
            }
            attemptedCount += 1
            do {
                let wasDeliveredInCurrentProcess: Bool
                if case .verified(let transaction) = verification {
                    wasDeliveredInCurrentProcess = processedTransactionStates.contains(
                        transaction.value.deliveryState
                    )
                } else {
                    wasDeliveredInCurrentProcess = false
                }
                let wasPersistedAsDelivered = await isPersistedAsDelivered(verification)
                try Task.checkCancellation()
                let wasDelivered = wasDeliveredInCurrentProcess || wasPersistedAsDelivered
                let transaction = try await process(verification)
                processedTransactions.append(transaction)
                if !wasDelivered { deliveredCount += 1 }
                if verificationCanFinish(verification) {
                    finishedCount += 1
                } else {
                    awaitingFinishCount += 1
                }
                await removeSupersededReferences(
                    recovery.supersededReferencesBySignedEvent[transaction.signedEventIdentifier] ?? []
                )
            } catch is CancellationError {
                break
            } catch {
                // 单笔失败不能阻止其他未完成交易继续处理。
                failureCount += 1
                continue
            }
        }

        // 重试完成后合并 StoreKit 与持久索引，并在需要时刷新订阅组首购资格。
        let snapshot = refreshStateAfterProcessing
            ? await refreshAfterProcessedTransactions(processedTransactions)
            : currentSnapshot
        return PaymentRetryReport(
            attemptedCount: attemptedCount,
            deliveredCount: deliveredCount,
            finishedCount: finishedCount,
            awaitingFinishCount: awaitingFinishCount,
            failureCount: failureCount,
            unresolvedCount: recovery.unresolvedCount,
            snapshot: snapshot
        )
    }

    /// 创建观察支付状态的异步事件流。
    ///
    /// 每个调用方会得到独立订阅；慢订阅者最多缓冲最近 100 条事件。
    public func events() -> AsyncStream<PaymentEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    /// 创建外部购买意图的异步流。
    ///
    /// 调用方可以先完成登录或引导流程，再把收到的意图传给 `purchase(intent:options:)`。
    /// 每个调用方会得到独立订阅；慢订阅者最多缓冲最近 20 条意图。
    public func purchaseIntents() -> AsyncStream<PaymentPurchaseIntent> {
        if purchaseIntentsSupported == false {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(20)) { continuation in
            purchaseIntentContinuations[id] = continuation
            for intent in pendingPurchaseIntents.values
                .map(\.value)
                .sorted(by: { $0.id < $1.id }) {
                continuation.yield(intent)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removePurchaseIntentContinuation(id) }
            }
        }
    }

    /// 放弃一项尚未处理的 App Store 外部购买意图。
    ///
    /// 该操作只移除当前客户端缓存的同一项意图，不会取消已经由 StoreKit 完成的交易。
    /// 后续交易仍会通过 `Transaction.updates` 进入可靠交付流程。
    ///
    /// - Parameter intent: 当前客户端通过 `purchaseIntents()` 返回的购买意图。
    /// - Returns: 成功移除时返回 `true`；意图已处理、已放弃或不属于当前客户端时返回 `false`。
    @discardableResult
    public func discardPurchaseIntent(_ intent: PaymentPurchaseIntent) -> Bool {
        guard let storedIntent = pendingPurchaseIntents[intent.id],
              storedIntent.value == intent else {
            return false
        }
        pendingPurchaseIntents[intent.id] = nil
        log(
            .info,
            category: "purchase-intent",
            message: "已放弃 App Store 外部购买意图",
            metadata: [
                "productID": intent.productID,
                "hasOffer": intent.offer == nil ? "false" : "true",
            ]
        )
        return true
    }

    /// 明确接管 App Store 系统消息的展示时机。
    ///
    /// - Important: 第一次调用后 PaymentKit 会开始消费 `Message.messages`，
    ///   StoreKit 不再自动展示这些消息。调用方必须展示或明确放弃每条消息。
    public func storeMessages() -> AsyncStream<PaymentStoreMessage> {
        isStoreMessageConsumptionRequested = true
        if storeMessagesSupported == false {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        if isStarted {
            startStoreMessageListener(generation: lifecycleGeneration)
        }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(20)) { continuation in
            storeMessageContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStoreMessageContinuation(id) }
            }
        }
    }

    /// 返回缓存的 StoreKit 原始商品。
    ///
    /// - Parameter productID: 商品标识符。
    /// - Returns: 最近一次商品加载得到的原始值；尚未加载时为 `nil`。
    public func storeKitProduct(for productID: String) -> Product? {
        storeProducts[productID]?.rawValue
    }

    /// 返回缓存的已验证 StoreKit 原始交易。
    ///
    /// - Parameter transactionID: 交易标识符。
    /// - Returns: 最近一次验签得到的原始值；未见过该交易时为 `nil`。
    public func storeKitTransaction(for transactionID: UInt64) -> Transaction? {
        storeTransactions[transactionID]?.rawValue
    }
}

private extension PaymentClient {
    func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        isStarted && lifecycleGeneration == generation
    }

    /// 在快照成功提交后按当前生命周期安排订阅时间边界。
    func scheduleStateBoundaryAfterSnapshotCommit(
        _ snapshot: PaymentSnapshot,
        requiredLifecycleGeneration: UInt64?,
        stateBoundaryContext: PaymentAutomaticRefreshBoundaryContext? = nil
    ) {
        guard isStarted else { return }
        let generation = requiredLifecycleGeneration ?? lifecycleGeneration
        guard isCurrentLifecycle(generation) else { return }

        guard let stateBoundaryContext else {
            scheduleNextStateBoundary(from: snapshot, generation: generation)
            return
        }
        scheduleStateBoundaryConvergence(
            from: snapshot,
            context: stateBoundaryContext,
            generation: generation
        )
    }

    /// 根据边界刷新结果决定结束收敛、安排新边界或执行下一次有限重试。
    func scheduleStateBoundaryConvergence(
        from snapshot: PaymentSnapshot,
        context: PaymentAutomaticRefreshBoundaryContext,
        generation: UInt64
    ) {
        guard isCurrentLifecycle(generation) else { return }
        let now = automaticRefreshClock.now()
        let stillReturnsSameBoundaryState =
            context.target.convergence != .none
                && PaymentAutomaticRefreshDeadline.target(
                    matching: context.target.key,
                    in: snapshot
                ) == context.target
                && context.target.key.date <= now
        guard stillReturnsSameBoundaryState else {
            scheduleNextStateBoundary(from: snapshot, generation: generation)
            return
        }

        let delays = PaymentAutomaticRefreshBoundaryRetry.delays
        guard context.nextRetryDelayIndex < delays.count else {
            stateBoundaryTask?.cancel()
            stateBoundaryTask = nil
            stateBoundaryContext = context
            if !exhaustedStateBoundaryTargets.contains(context.target) {
                exhaustedStateBoundaryTargets.append(context.target)
            }
            log(
                .warning,
                category: "automatic-refresh",
                message: "订阅时间边界状态在有限重试后仍未收敛"
            )
            scheduleNextStateBoundary(from: snapshot, generation: generation)
            return
        }

        let retryDelay = delays[context.nextRetryDelayIndex]
        scheduleStateBoundarySleep(
            at: now.addingTimeInterval(retryDelay),
            context: PaymentAutomaticRefreshBoundaryContext(
                target: context.target,
                nextRetryDelayIndex: context.nextRetryDelayIndex + 1
            ),
            generation: generation
        )
    }

    /// 安排一次不保活客户端的边界睡眠。
    func scheduleStateBoundarySleep(
        at deadline: Date,
        context: PaymentAutomaticRefreshBoundaryContext,
        generation: UInt64
    ) {
        stateBoundaryTask?.cancel()
        stateBoundaryContext = context
        let clock = automaticRefreshClock
        let clientReference = WeakPaymentClientReference(self)
        stateBoundaryTask = Task {
            do {
                if context.nextRetryDelayIndex == 0 {
                    try await clock.sleep(deadline)
                } else {
                    try await clock.retrySleep(deadline)
                }
            } catch {
                return
            }
            guard !Task.isCancelled, let client = clientReference.value else {
                return
            }
            await client.refreshStateAtBoundary(
                context,
                generation: generation
            )
        }
    }

    /// 在指定生命周期内执行一次轻量边界刷新。
    func refreshStateAtBoundary(
        _ context: PaymentAutomaticRefreshBoundaryContext,
        generation: UInt64
    ) async {
        guard isCurrentLifecycle(generation), !Task.isCancelled else { return }
        requestAutomaticRefresh(
            .state,
            reason: "subscription-boundary",
            generation: generation,
            stateBoundaryContext: context
        )
    }

    func checkRequiredLifecycle(_ generation: UInt64?) throws {
        guard let generation else { return }
        try Task.checkCancellation()
        guard isCurrentLifecycle(generation) else {
            throw CancellationError()
        }
    }

    /// 执行由生命周期任务拥有的启动重放和首次状态加载。
    func performInitialStartup(generation: UInt64) async {
        guard isCurrentLifecycle(generation), !Task.isCancelled else { return }
        _ = await retryUnfinishedTransactions()
        guard isCurrentLifecycle(generation), !Task.isCancelled else { return }
        do {
            _ = try await refresh()
        } catch is CancellationError {
            log(.debug, category: "lifecycle", message: "初始状态加载已取消")
        } catch {
            log(.error, category: "lifecycle", message: "初始状态加载失败")
        }
    }

    /// 消费应用激活事件，并将其转换为当前生命周期的完整刷新请求。
    nonisolated static func listenForApplicationActivity(
        _ events: AsyncStream<Void>,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async {
        for await _ in events {
            guard !Task.isCancelled else { return }
            guard await requestAutomaticRefresh(
                clientReference,
                .full,
                reason: "application-active",
                generation: generation,
                replaysUnfinishedTransactions: true
            ) else { return }
        }
    }

    nonisolated static func requestAutomaticRefresh(
        _ clientReference: WeakPaymentClientReference,
        _ strength: PaymentAutomaticRefreshStrength,
        reason: String,
        generation: UInt64,
        replaysUnfinishedTransactions: Bool = false
    ) async -> Bool {
        guard let client = clientReference.value else { return false }
        await client.requestAutomaticRefresh(
            strength,
            reason: reason,
            generation: generation,
            replaysUnfinishedTransactions: replaysUnfinishedTransactions
        )
        return true
    }

    /// 保存 StoreKit 已验签状态事件，使紧随其后的陈旧组查询不能覆盖它。
    private func receiveSubscriptionStatusUpdate(
        _ result: StoreSubscriptionStatusResult,
        generation: UInt64
    ) -> Bool {
        guard isCurrentLifecycle(generation) else { return false }
        guard result != lastSubscriptionStatusUpdate else { return true }
        lastSubscriptionStatusUpdate = result
        for failure in result.verificationFailures {
            reportVerificationFailure(
                transactionID: failure.transactionID,
                message: failure.message
            )
        }
        for groupID in result.replacedGroupIDs {
            authoritativeSubscriptionStatusGroupIDs.insert(groupID)
            cachedSubscriptionStatusUpdates = cachedSubscriptionStatusUpdates
                .filter { $0.value.status.groupID != groupID }
        }
        for status in result.statuses {
            let signedDate = result.renewalInfoSignedDatesByStatusID[status.id]
            if let existing = cachedSubscriptionStatusUpdates[status.id],
               let existingSignedDate = existing.renewalInfoSignedDate,
               let signedDate,
               signedDate < existingSignedDate {
                continue
            }
            cachedSubscriptionStatusUpdates[status.id] =
                CachedSubscriptionStatusUpdate(
                    status: status,
                    renewalInfoSignedDate: signedDate
                )
        }
        requestAutomaticRefresh(
            .state,
            reason: "subscription-status",
            generation: generation
        )
        return true
    }

    /// 以续订签署时间合并事件与查询，事件时间缺失时按到达顺序优先。
    private func reconcileSubscriptionStatusResult(
        _ result: StoreSubscriptionStatusResult,
        requestedGroupIDs: Set<String>
    ) -> StoreSubscriptionStatusResult {
        var statuses = result.statuses
        var signedDates = result.renewalInfoSignedDatesByStatusID
        let authoritativeGroupIDs =
            authoritativeSubscriptionStatusGroupIDs.intersection(
                requestedGroupIDs
            )
        let replacedStatusIDs = statuses.compactMap { status in
            authoritativeGroupIDs.contains(status.groupID) ? status.id : nil
        }
        statuses.removeAll {
            authoritativeGroupIDs.contains($0.groupID)
        }
        for statusID in replacedStatusIDs {
            signedDates.removeValue(forKey: statusID)
        }
        let cachedUpdates = cachedSubscriptionStatusUpdates
            .values
            .filter { requestedGroupIDs.contains($0.status.groupID) }
            .sorted { $0.status.id < $1.status.id }

        for update in cachedUpdates {
            if authoritativeGroupIDs.contains(update.status.groupID) {
                statuses.append(update.status)
                if let updateSignedDate = update.renewalInfoSignedDate {
                    signedDates[update.status.id] = updateSignedDate
                }
                continue
            }
            if let index = statuses.firstIndex(where: {
                $0.id == update.status.id
            }) {
                let queriedSignedDate = signedDates[update.status.id]
                if let queriedSignedDate,
                   let updateSignedDate = update.renewalInfoSignedDate,
                   queriedSignedDate > updateSignedDate {
                    cachedSubscriptionStatusUpdates.removeValue(
                        forKey: update.status.id
                    )
                    continue
                }
                statuses[index] = update.status
            } else {
                statuses.append(update.status)
            }
            if let updateSignedDate = update.renewalInfoSignedDate {
                signedDates[update.status.id] = updateSignedDate
            }
        }

        return StoreSubscriptionStatusResult(
            statuses: statuses,
            verificationFailures: result.verificationFailures,
            renewalInfoSignedDatesByStatusID: signedDates,
            replacedGroupIDs: result.replacedGroupIDs
        )
    }

    /// 使用 iOS 18.4+ 的交易维度查询交叉校验订阅组缓存。
    private func crossCheckSubscriptionStatusesByTransactionID(
        _ result: StoreSubscriptionStatusResult
    ) async -> StoreSubscriptionStatusResult {
        var statuses = result.statuses
        var failures = result.verificationFailures
        var signedDates = result.renewalInfoSignedDatesByStatusID
        var replacedGroupIDs = result.replacedGroupIDs

        for queriedStatus in result.statuses {
            guard !Task.isCancelled else { break }
            guard let directResult = await gateway.subscriptionStatus(
                forTransactionID: queriedStatus.transaction.id
            ) else {
                continue
            }
            failures.append(contentsOf: directResult.verificationFailures)
            replacedGroupIDs.formUnion(directResult.replacedGroupIDs)

            for directStatus in directResult.statuses {
                let directSignedDate =
                    directResult.renewalInfoSignedDatesByStatusID[directStatus.id]
                if let index = statuses.firstIndex(where: {
                    $0.id == directStatus.id
                }) {
                    let queriedSignedDate = signedDates[directStatus.id]
                    if let queriedSignedDate,
                       let directSignedDate,
                       directSignedDate < queriedSignedDate {
                        continue
                    }
                    statuses[index] = directStatus
                } else {
                    statuses.append(directStatus)
                }
                if let directSignedDate {
                    signedDates[directStatus.id] = directSignedDate
                }
            }
        }

        return StoreSubscriptionStatusResult(
            statuses: statuses,
            verificationFailures: failures,
            renewalInfoSignedDatesByStatusID: signedDates,
            replacedGroupIDs: replacedGroupIDs
        )
    }

    nonisolated static func receiveSubscriptionStatusUpdate(
        _ result: StoreSubscriptionStatusResult,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async -> Bool {
        guard let client = clientReference.value else { return false }
        return await client.receiveSubscriptionStatusUpdate(
            result,
            generation: generation
        )
    }

    /// 消费 StoreKit 订阅状态变化，并在序列意外结束后有限退避重建监听。
    nonisolated static func listenForSubscriptionStatusUpdates(
        _ initialUpdates: AsyncStream<StoreSubscriptionStatusResult>,
        gateway: any PaymentStoreGateway,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async {
        var updates = initialUpdates
        var retryDelayMilliseconds: UInt64 = 250
        var hasLoggedUnexpectedTermination = false

        while await clientIsCurrent(
            clientReference,
            generation: generation
        ), !Task.isCancelled {
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard await receiveSubscriptionStatusUpdate(
                    update,
                    clientReference: clientReference,
                    generation: generation
                ) else { return }
            }

            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            if !hasLoggedUnexpectedTermination {
                await logSubscriptionStatusListenerReconnect(clientReference)
                hasLoggedUnexpectedTermination = true
            }
            do {
                try await Task.sleep(
                    nanoseconds: retryDelayMilliseconds * 1_000_000
                )
            } catch {
                return
            }
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            updates = await gateway.subscriptionStatusUpdates()
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 4_000)
        }
    }

    nonisolated static func logSubscriptionStatusListenerReconnect(
        _ clientReference: WeakPaymentClientReference
    ) async {
        guard let client = clientReference.value else { return }
        await client.log(
            .warning,
            category: "subscription-status",
            message: "订阅状态监听意外结束，准备重新建立"
        )
    }

    /// 消费不携带标识的 Storefront 信号，并在序列结束后有限退避重建监听。
    nonisolated static func listenForStorefrontUpdates(
        _ initialUpdates: AsyncStream<Void>,
        gateway: any PaymentStoreGateway,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async {
        var updates = initialUpdates
        var retryDelayMilliseconds: UInt64 = 250

        while await clientIsCurrent(
            clientReference,
            generation: generation
        ), !Task.isCancelled {
            var receivedUpdate = false
            for await _ in updates {
                guard !Task.isCancelled else { return }
                guard await requestAutomaticRefresh(
                    clientReference,
                    .full,
                    reason: "storefront",
                    generation: generation
                ) else { return }
                receivedUpdate = true
            }

            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            await logStorefrontListenerReconnect(clientReference)
            if receivedUpdate {
                retryDelayMilliseconds = 250
            }
            do {
                // iOS 15 可用的纳秒休眠让连续结束逐步退避，最长不超过四秒。
                try await Task.sleep(
                    nanoseconds: retryDelayMilliseconds * 1_000_000
                )
            } catch {
                return
            }
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            updates = await gateway.storefrontUpdates()
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 4_000)
        }
    }

    nonisolated static func logStorefrontListenerReconnect(
        _ clientReference: WeakPaymentClientReference
    ) async {
        guard let client = clientReference.value else { return }
        await client.log(
            .warning,
            category: "storefront",
            message: "Storefront 监听意外结束，准备重新建立"
        )
    }

    /// 执行一个自动刷新批次，并在 actor 重入期间保留新到达的请求。
    func runAutomaticRefreshTask(generation: UInt64) async {
        defer {
            // 旧任务恢复时不能清除新生命周期已经创建的自动刷新任务。
            if lifecycleGeneration == generation {
                automaticRefreshTask = nil
            }
        }

        do {
            // iOS 15 可用的纳秒接口避免引入较新系统的 Clock API。
            try await Task.sleep(nanoseconds: 150_000_000)
        } catch {
            return
        }

        var completedRefreshCount = 0
        while isCurrentLifecycle(generation), !Task.isCancelled {
            guard let strength = pendingAutomaticRefreshStrength else { return }
            // 在首个 StoreKit await 前清空当前批次；重入触发会写入下一批。
            pendingAutomaticRefreshStrength = nil
            let replaysUnfinishedTransactions =
                pendingAutomaticRefreshReplaysUnfinishedTransactions
            pendingAutomaticRefreshReplaysUnfinishedTransactions = false
            let stateBoundaryContext = pendingAutomaticRefreshBoundaryContext
            pendingAutomaticRefreshBoundaryContext = nil
            let start = DispatchTime.now().uptimeNanoseconds

            if replaysUnfinishedTransactions {
                let unfinished = await gateway.unfinishedTransactions()
                guard isCurrentLifecycle(generation), !Task.isCancelled else {
                    return
                }
                let replayReport = await retryUnfinishedTransactions(
                    including: unfinished,
                    requiredLifecycleGeneration: generation,
                    refreshStateAfterProcessing: false
                )
                guard isCurrentLifecycle(generation), !Task.isCancelled else {
                    return
                }
                log(
                    replayReport.failureCount == 0 ? .info : .warning,
                    category: "automatic-refresh",
                    message: "前台恢复已完成 unfinished 交易重放",
                    metadata: [
                        "attemptedCount": "\(replayReport.attemptedCount)",
                        "failureCount": "\(replayReport.failureCount)",
                        "unresolvedCount": "\(replayReport.unresolvedCount)",
                    ]
                )
            }

            switch strength {
            case .state:
                _ = await refreshStateWithoutReloadingProducts(
                    requiredLifecycleGeneration: generation,
                    stateBoundaryContext: stateBoundaryContext
                )
            case .full:
                do {
                    _ = try await refresh(
                        requiredLifecycleGeneration: generation,
                        stateBoundaryContext: stateBoundaryContext
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard isCurrentLifecycle(generation), !Task.isCancelled else {
                        return
                    }
                    // 不记录 StoreKit 原始错误，避免错误对象携带账户或资格信息。
                    log(
                        .warning,
                        category: "automatic-refresh",
                        message: "自动刷新失败，保留最近一次完整快照",
                        metadata: [
                            "strength": strength.logName,
                            "durationMilliseconds": "\(durationMilliseconds(since: start))",
                        ]
                    )
                    if let stateBoundaryContext {
                        scheduleStateBoundaryConvergence(
                            from: currentSnapshot,
                            context: stateBoundaryContext,
                            generation: generation
                        )
                    }
                    continue
                }
            }

            guard isCurrentLifecycle(generation), !Task.isCancelled else { return }
            completedRefreshCount += 1
            log(
                .info,
                category: "automatic-refresh",
                message: "自动刷新完成",
                metadata: [
                    "strength": strength.logName,
                    "durationMilliseconds": "\(durationMilliseconds(since: start))",
                    "refreshCount": "\(completedRefreshCount)",
                ]
            )
        }
    }

    /// 消费 App Store 外部购买意图；停止客户端后旧生命周期不得再提交意图。
    nonisolated static func listenForPurchaseIntents(
        _ initialIntents: AsyncStream<StorePurchaseIntent>,
        gateway: any PaymentStoreGateway,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async {
        var intents = initialIntents
        var retryDelayMilliseconds: UInt64 = 250

        while await clientIsCurrent(
            clientReference,
            generation: generation
        ), !Task.isCancelled {
            var receivedIntent = false
            for await intent in intents {
                guard !Task.isCancelled,
                      await receivePurchaseIntent(
                          intent,
                          clientReference: clientReference,
                          generation: generation
                      )
                else { return }
                receivedIntent = true
            }

            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            await logPurchaseIntentReconnect(clientReference)

            // 短暂稳定运行后从最小退避重新开始；连续结束时逐步延长到 4 秒。
            if receivedIntent {
                retryDelayMilliseconds = 250
            }
            do {
                try await Task.sleep(
                    nanoseconds: retryDelayMilliseconds * 1_000_000
                )
            } catch {
                return
            }
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            intents = await gateway.purchaseIntents()
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 4_000)
        }
    }

    nonisolated static func receivePurchaseIntent(
        _ intent: StorePurchaseIntent,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async -> Bool {
        guard let client = clientReference.value else { return false }
        return await client.receivePurchaseIntent(
            intent,
            generation: generation
        )
    }

    func receivePurchaseIntent(
        _ intent: StorePurchaseIntent,
        generation: UInt64
    ) -> Bool {
        guard isCurrentLifecycle(generation) else { return false }
        pendingPurchaseIntents[intent.value.id] = intent
        storeProducts[intent.value.productID] = intent.product
        for continuation in purchaseIntentContinuations.values {
            continuation.yield(intent.value)
        }
        log(
            .info,
            category: "purchase-intent",
            message: "收到 App Store 外部购买意图",
            metadata: [
                "productID": intent.value.productID,
                "hasOffer": intent.value.offer == nil ? "false" : "true",
            ]
        )
        return true
    }

    nonisolated static func logPurchaseIntentReconnect(
        _ clientReference: WeakPaymentClientReference
    ) async {
        guard let client = clientReference.value else { return }
        await client.log(
            .warning,
            category: "purchase-intent",
            message: "购买意图监听意外结束，准备重新建立"
        )
    }

    /// 在调用方明确订阅后建立 StoreKit 系统消息监听。
    func startStoreMessageListener(generation: UInt64) {
        guard storeMessageTask == nil, isCurrentLifecycle(generation) else { return }
        let clientReference = WeakPaymentClientReference(self)
        let storeMessageGateway = gateway
        storeMessageTask = Task {
            let isSupported = await storeMessageGateway.supportsStoreMessages()
            guard await Self.resolveStoreMessageSupport(
                isSupported,
                clientReference: clientReference,
                generation: generation
            ), !Task.isCancelled else {
                return
            }
            let messages = await storeMessageGateway.storeMessages()
            await Self.listenForStoreMessages(
                messages,
                gateway: storeMessageGateway,
                clientReference: clientReference,
                generation: generation
            )
        }
    }

    nonisolated static func resolveStoreMessageSupport(
        _ isSupported: Bool,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async -> Bool {
        guard let client = clientReference.value else { return false }
        return await client.resolveStoreMessageSupport(
            isSupported,
            generation: generation
        )
    }

    /// 提交 Store Message 能力检查结果，并在不支持时结束所有等待中的公开流。
    func resolveStoreMessageSupport(
        _ isSupported: Bool,
        generation: UInt64
    ) -> Bool {
        guard isCurrentLifecycle(generation) else {
            storeMessageListenerDidFinish(generation: generation)
            return false
        }
        storeMessagesSupported = isSupported
        guard isSupported else {
            finishStoreMessageContinuations()
            storeMessageListenerDidFinish(generation: generation)
            return false
        }
        return true
    }

    /// 转发系统消息；旧生命周期或取消后的消息不会提交到界面。
    nonisolated static func listenForStoreMessages(
        _ initialMessages: AsyncStream<PaymentStoreMessage>,
        gateway: any PaymentStoreGateway,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async {
        var messages = initialMessages
        var retryDelayMilliseconds: UInt64 = 250

        while await clientIsCurrent(
            clientReference,
            generation: generation
        ), !Task.isCancelled {
            var receivedMessage = false
            for await message in messages {
                guard !Task.isCancelled,
                      await receiveStoreMessage(
                          message,
                          clientReference: clientReference,
                          generation: generation
                      )
                else { return }
                receivedMessage = true
            }

            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            await logStoreMessageReconnect(clientReference)
            if receivedMessage {
                retryDelayMilliseconds = 250
            }
            do {
                try await Task.sleep(
                    nanoseconds: retryDelayMilliseconds * 1_000_000
                )
            } catch {
                return
            }
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            messages = await gateway.storeMessages()
            retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 4_000)
        }

        await finishStoreMessageListener(
            clientReference,
            generation: generation
        )
    }

    nonisolated static func receiveStoreMessage(
        _ message: PaymentStoreMessage,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async -> Bool {
        guard let client = clientReference.value else { return false }
        return await client.receiveStoreMessage(
            message,
            generation: generation
        )
    }

    func receiveStoreMessage(
        _ message: PaymentStoreMessage,
        generation: UInt64
    ) -> Bool {
        guard isCurrentLifecycle(generation) else { return false }
        for continuation in storeMessageContinuations.values {
            continuation.yield(message)
        }
        log(
            .info,
            category: "store-message",
            message: "收到 App Store 系统消息",
            metadata: ["reason": "\(message.reason)"]
        )
        return true
    }

    nonisolated static func logStoreMessageReconnect(
        _ clientReference: WeakPaymentClientReference
    ) async {
        guard let client = clientReference.value else { return }
        await client.log(
            .warning,
            category: "store-message",
            message: "系统消息监听意外结束，准备重新建立"
        )
    }

    nonisolated static func finishStoreMessageListener(
        _ clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async {
        await clientReference.value?.storeMessageListenerDidFinish(
            generation: generation
        )
    }

    func storeMessageListenerDidFinish(generation: UInt64) {
        if lifecycleGeneration == generation {
            storeMessageTask = nil
        }
    }

    /// 以受控并发消费交易更新，并在更新序列意外结束时按退避策略重新建立监听。
    nonisolated static func listenForTransactionUpdates(
        initialUpdates: AsyncStream<StoreTransactionVerification>,
        gateway: any PaymentStoreGateway,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async {
        var updates = initialUpdates
        var retryDelayMilliseconds: UInt64 = 250

        while await clientIsCurrent(
            clientReference,
            generation: generation
        ), !Task.isCancelled {
            await withTaskGroup(of: Void.self) { group in
                var activeCount = 0
                for await verification in updates {
                    guard !Task.isCancelled,
                          await clientIsCurrent(
                              clientReference,
                              generation: generation
                          )
                    else { break }

                    // 固定并发上限可避免慢后台造成队头阻塞，同时限制突发更新的资源占用。
                    if activeCount >= Self.maximumConcurrentTransactionUpdates {
                        _ = await group.next()
                        activeCount -= 1
                    }
                    activeCount += 1
                    group.addTask {
                        await receiveTransactionUpdate(
                            verification,
                            clientReference: clientReference,
                            generation: generation
                        )
                    }
                }

                group.cancelAll()
                while await group.next() != nil {}
            }

            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            await logTransactionListenerReconnect(
                clientReference,
                .warning,
                message: "交易更新监听意外结束，准备重新建立",
                metadata: ["retryDelayMilliseconds": "\(retryDelayMilliseconds)"]
            )

            do {
                try await Task.sleep(nanoseconds: retryDelayMilliseconds * 1_000_000)
            } catch {
                return
            }
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }

            // 先重新建立 StoreKit 更新流，让重放期间到达的新交易由新监听缓冲。
            // 随后主动重放 outbox，避免上一批次被取消的交易只能依赖下一次更新或重启恢复。
            updates = await gateway.transactionUpdates()
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }

            guard let replayReport = await replayUnfinishedTransactions(
                clientReference
            ) else { return }
            guard await clientIsCurrent(
                clientReference,
                generation: generation
            ), !Task.isCancelled else { return }
            await logTransactionListenerReconnect(
                clientReference,
                replayReport.failureCount == 0 ? .info : .warning,
                message: "交易更新监听已重建并完成 outbox 重放",
                metadata: [
                    "replayAttemptedCount": "\(replayReport.attemptedCount)",
                    "replayFailureCount": "\(replayReport.failureCount)",
                    "remainingBacklogCount": "\(replayReport.snapshot.pendingTransactions.count)",
                ]
            )
            retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 4_000)
        }
    }

    nonisolated static func clientIsCurrent(
        _ clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async -> Bool {
        guard let client = clientReference.value else { return false }
        return await client.isCurrentLifecycle(generation)
    }

    nonisolated static func receiveTransactionUpdate(
        _ verification: StoreTransactionVerification,
        clientReference: WeakPaymentClientReference,
        generation: UInt64
    ) async {
        await clientReference.value?.receiveTransactionUpdate(
            verification,
            generation: generation
        )
    }

    nonisolated static func replayUnfinishedTransactions(
        _ clientReference: WeakPaymentClientReference
    ) async -> PaymentRetryReport? {
        guard let client = clientReference.value else { return nil }
        return await client.retryUnfinishedTransactions()
    }

    nonisolated static func logTransactionListenerReconnect(
        _ clientReference: WeakPaymentClientReference,
        _ level: PaymentLogLevel,
        message: String,
        metadata: [String: String]
    ) async {
        guard let client = clientReference.value else { return }
        await client.log(
            level,
            category: "lifecycle",
            message: message,
            metadata: metadata
        )
    }

    func receiveTransactionUpdate(
        _ verification: StoreTransactionVerification,
        generation: UInt64
    ) async {
        guard isCurrentLifecycle(generation) else { return }
        do {
            let transaction = try await process(verification)
            guard isCurrentLifecycle(generation) else { return }
            _ = await refreshAfterProcessedTransactions([transaction])
        } catch is CancellationError {
            return
        } catch {
            // 错误已经由 process(_:) 记录并发布，监听任务继续等待后续交易。
        }
    }

    func process(_ verification: StoreTransactionVerification) async throws -> PaymentTransaction {
        switch verification {
        case .unverified(let transactionID, let message):
            reportVerificationFailure(transactionID: transactionID, message: message)
            throw PaymentError(
                code: .verificationFailed,
                message: "StoreKit 交易验签失败",
                transactionID: transactionID
            )
        case .verified(let transaction):
            return try await processVerifiedTransaction(transaction)
        }
    }

    func processVerifiedTransaction(_ transaction: StoreTransaction) async throws -> PaymentTransaction {
        try Task.checkCancellation()
        let value = transaction.value
        let signedEventID = value.signedEventIdentifier
        let deliveryState = value.deliveryState
        let pendingReference = PendingTransactionReference(transaction: value)
        let processingStartedAt = DispatchTime.now().uptimeNanoseconds
        storeTransactions[value.id] = transaction

        // 同一交易可能从购买结果和 Transaction.updates 以不同 JWS 重新签名到达。
        if processedTransactionStates.contains(deliveryState) {
            if transaction.canFinish {
                // StoreKit 只有在仍认为交易未结束时才会再次通过 unfinished 返回它。
                // 后台交付已经完成，但 finish 本身可安全重复调用，必须在此补做。
                try Task.checkCancellation()
                await gateway.finish(transaction)
                await removePendingReference(pendingReference)
                awaitingFinishTransactionStates.remove(deliveryState)
                emit(.transactionDelivered(value, finishState: .finished))
                log(
                    .info,
                    category: "transactions",
                    message: "StoreKit 再次报告已交付交易，已补 finish",
                    metadata: ["transactionSuffix": transactionSuffix(value.id)]
                )
            }
            log(
                .debug,
                category: "transactions",
                message: "跳过业务状态未变化交易的重复后台交付",
                metadata: ["transactionSuffix": transactionSuffix(value.id)]
            )
            return value
        }
        if let primarySignedEventID = processingTransactionStateEvents[deliveryState] {
            log(
                .debug,
                category: "transactions",
                message: "等待正在处理的相同交易状态",
                metadata: ["transactionSuffix": transactionSuffix(value.id)]
            )
            // 重复调用必须等待首个处理结果，不能在 finish 前提前报告 completed。
            _ = try await waitForSignedEvent(primarySignedEventID)
            try await finishAfterSharedProcessingIfNeeded(
                transaction,
                fallbackReference: pendingReference
            )
            return value
        }
        processingSignedEvents.insert(signedEventID)
        processingTransactionStateEvents[deliveryState] = signedEventID

        do {
            let existingReference: PendingTransactionReference?
            let backlogCount: Int
            do {
                let references = try await pendingStore.references()
                let exactReference = references.first {
                    $0 == pendingReference
                }
                existingReference = references.first {
                    $0.recordsCompletedDelivery(of: value)
                } ?? exactReference
                backlogCount = references.count + (existingReference == nil ? 1 : 0)
            } catch {
                throw persistenceError(for: value, operation: "读取待交付状态")
            }
            if existingReference?.isDelivered == true {
                // outbox 已经证明后台交付完成。必须在任何 finish/清理 await 之前
                // 记录业务状态，避免并发刷新把同一交易的较新重签名重新提交为 pending。
                processedTransactionStates.insert(deliveryState)
                if transaction.canFinish {
                    // 后台已在上次进程完成交付，此处只补做 StoreKit finish。
                    try Task.checkCancellation()
                    await gateway.finish(transaction)
                    await removePendingReference(existingReference ?? pendingReference)
                    completeSignedEvent(signedEventID, transaction: value)
                    emit(.transactionDelivered(value, finishState: .finished))
                    log(
                        .info,
                        category: "transactions",
                        message: "已结束先前完成后台交付的交易",
                        metadata: ["transactionSuffix": transactionSuffix(value.id)]
                    )
                } else {
                    awaitingFinishTransactionStates.insert(deliveryState)
                    completeSignedEvent(signedEventID, transaction: value)
                    emit(.transactionDelivered(value, finishState: .awaitingStoreKit))
                    log(
                        .debug,
                        category: "transactions",
                        message: "后台已交付，继续等待 StoreKit 原始交易以结束",
                        metadata: ["transactionSuffix": transactionSuffix(value.id)]
                    )
                }
                return value
            }
            do {
                // 必须先落盘再调用后台，覆盖后台成功后应用在 finish 前退出的窗口。
                try await pendingStore.insert(pendingReference)
            } catch {
                log(
                    .error,
                    category: "transactions",
                    message: "保存待交付交易记录失败并保持未完成",
                    metadata: ["transactionSuffix": transactionSuffix(value.id)]
                )
                throw persistenceError(for: value, operation: "保存待交付状态")
            }
            try Task.checkCancellation()
            log(
                .info,
                category: "transactions",
                message: "开始处理已验证交易",
                metadata: [
                    "backlogCount": "\(backlogCount)",
                    "productID": value.productID,
                    "stage": "delivery",
                    "transactionSuffix": transactionSuffix(value.id),
                ]
            )
            try await processor.process(value)

            // 后台完成后必须先持久标记“已交付”；只有该写入成功，才允许结束 StoreKit 交易。
            try Task.checkCancellation()
            do {
                try await pendingStore.markDelivered(pendingReference)
            } catch {
                throw persistenceError(for: value, operation: "保存已交付状态")
            }

            // 持久标记成功即代表后台可靠交付完成；StoreKit finish 是之后的独立阶段。
            // 提前登记可让 actor 在 finish 和 outbox 清理期间重入时，仍能识别等价重签名。
            processedTransactionStates.insert(deliveryState)

            // 标记完成后若任务被取消，记录会保留为 deliveredAwaitingFinish；重启不会重复交付。
            try Task.checkCancellation()
            let finishState: PaymentFinishState
            if transaction.canFinish {
                await gateway.finish(transaction)
                await removePendingReference(pendingReference)
                finishState = .finished
            } else {
                // StoreKit 完全漏报时保留已交付记录，等待未来取得原始交易后再 finish。
                awaitingFinishTransactionStates.insert(deliveryState)
                finishState = .awaitingStoreKit
            }
            completeSignedEvent(signedEventID, transaction: value)
            emit(.transactionDelivered(value, finishState: finishState))
            log(
                transaction.canFinish ? .info : .warning,
                category: "transactions",
                message: transaction.canFinish
                    ? "交易处理并结束"
                    : "交易已完成后台交付，等待 StoreKit 原始交易以结束",
                metadata: [
                    "backlogCount": "\(backlogCount)",
                    "durationMilliseconds": "\(durationMilliseconds(since: processingStartedAt))",
                    "productID": value.productID,
                    "stage": finishState == .finished ? "finished" : "awaitingStoreKit",
                    "transactionSuffix": transactionSuffix(value.id),
                ]
            )
            return value
        } catch is CancellationError {
            failSignedEvent(signedEventID, transaction: value, error: CancellationError())
            log(.warning, category: "transactions", message: "交易处理已取消并保持未完成")
            throw CancellationError()
        } catch let paymentError as PaymentError {
            failSignedEvent(signedEventID, transaction: value, error: paymentError)
            emit(.transactionProcessingFailed(transaction: value, error: paymentError))
            log(
                .error,
                category: "transactions",
                message: "交易处理失败并保持未完成",
                metadata: [
                    "productID": value.productID,
                    "transactionSuffix": transactionSuffix(value.id),
                ]
            )
            throw paymentError
        } catch {
            let paymentError = PaymentError(
                code: .processingFailed,
                message: "交易处理器未完成可靠交付",
                productID: value.productID,
                transactionID: value.id
            )
            failSignedEvent(signedEventID, transaction: value, error: paymentError)
            emit(.transactionProcessingFailed(transaction: value, error: paymentError))
            log(
                .error,
                category: "transactions",
                message: "交易处理失败并保持未完成",
                metadata: [
                    "productID": value.productID,
                    "transactionSuffix": transactionSuffix(value.id),
                ]
            )
            throw paymentError
        }
    }

    func waitForSignedEvent(_ signedEventID: String) async throws -> PaymentTransaction {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                processingSignedEventWaiters[signedEventID, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelSignedEventWaiter(signedEventID, waiterID: waiterID) }
        }
    }

    func cancelSignedEventWaiter(_ signedEventID: String, waiterID: UUID) {
        guard let waiter = processingSignedEventWaiters[signedEventID]?.removeValue(
            forKey: waiterID
        ) else { return }
        if processingSignedEventWaiters[signedEventID]?.isEmpty == true {
            processingSignedEventWaiters[signedEventID] = nil
        }
        waiter.resume(throwing: CancellationError())
    }

    func completeSignedEvent(
        _ signedEventID: String,
        transaction: PaymentTransaction
    ) {
        processingSignedEvents.remove(signedEventID)
        if processingTransactionStateEvents[transaction.deliveryState] == signedEventID {
            processingTransactionStateEvents[transaction.deliveryState] = nil
        }
        processedTransactionStates.insert(transaction.deliveryState)

        // 唤醒所有并发重复调用，使它们共享完全相同的可靠交付结果。
        let waiters = processingSignedEventWaiters.removeValue(forKey: signedEventID) ?? [:]
        waiters.values.forEach { $0.resume(returning: transaction) }
    }

    func failSignedEvent(
        _ signedEventID: String,
        transaction: PaymentTransaction,
        error: any Error
    ) {
        processingSignedEvents.remove(signedEventID)
        if processingTransactionStateEvents[transaction.deliveryState] == signedEventID {
            processingTransactionStateEvents[transaction.deliveryState] = nil
        }

        // 首次处理失败时，并发重复调用也必须失败并保留 unfinished。
        let waiters = processingSignedEventWaiters.removeValue(forKey: signedEventID) ?? [:]
        waiters.values.forEach { $0.resume(throwing: error) }
    }

    /// 当 outbox 快照先完成交付时，让随后到达的真实 StoreKit 句柄补做 finish。
    ///
    /// 只有仍存在等价“已交付待 finish”状态时才执行，避免两个真实句柄并发时
    /// 对已经由 leader 结束的交易重复调用 finish。状态变化较新的记录不会被删除。
    func finishAfterSharedProcessingIfNeeded(
        _ transaction: StoreTransaction,
        fallbackReference: PendingTransactionReference
    ) async throws {
        try Task.checkCancellation()
        guard transaction.canFinish else { return }
        let value = transaction.value
        let stateWasAwaitingStoreKit = awaitingFinishTransactionStates.contains(
            value.deliveryState
        )
        let deliveredReferences: Set<PendingTransactionReference>
        do {
            deliveredReferences = Set(
                try await pendingStore.references().filter {
                    $0.recordsCompletedDelivery(of: value)
                }
            )
        } catch {
            // 内存状态仍能证明本进程已经可靠交付；finish 后保留 outbox 供下次清理。
            deliveredReferences = []
            log(
                .warning,
                category: "persistence",
                message: "补 finish 前读取待交付状态失败"
            )
        }
        guard stateWasAwaitingStoreKit || !deliveredReferences.isEmpty else { return }

        try Task.checkCancellation()
        await gateway.finish(transaction)
        if deliveredReferences.isEmpty {
            await removePendingReference(fallbackReference)
        } else {
            for reference in deliveredReferences {
                await removePendingReference(reference)
            }
        }
        awaitingFinishTransactionStates.remove(value.deliveryState)
        emit(.transactionDelivered(value, finishState: .finished))
        log(
            .info,
            category: "transactions",
            message: "真实 StoreKit 交易已补做 finish",
            metadata: ["transactionSuffix": transactionSuffix(value.id)]
        )
    }

    func refreshStateWithoutReloadingProducts(
        requiredLifecycleGeneration: UInt64? = nil,
        stateBoundaryContext: PaymentAutomaticRefreshBoundaryContext? = nil
    ) async -> PaymentSnapshot {
        stateRefreshRequestID &+= 1
        let requestID = stateRefreshRequestID

        while !Task.isCancelled {
            let productVersion = committedProductLoadRequestID
            let groupIDs = Set(currentSnapshot.products.compactMap { $0.subscription?.groupID })
            let entitlementResults = await gateway.currentEntitlements()
            let storeUnfinishedResults = await gateway.unfinishedTransactions()
            let unfinishedResults = await recoverPersistedTransactions(
                including: storeUnfinishedResults
            ).verifications
            let queriedSubscriptionResult = await gateway.subscriptionStatuses(
                for: groupIDs
            )
            let transactionCheckedSubscriptionResult =
                await crossCheckSubscriptionStatusesByTransactionID(
                    queriedSubscriptionResult
                )
            let subscriptionResult = reconcileSubscriptionStatusResult(
                transactionCheckedSubscriptionResult,
                requestedGroupIDs: groupIDs
            )
            let canMakePayments = await gateway.canMakePayments()

            // 商品加载与状态刷新并发时，使用新商品集合重新查询订阅组。
            guard productVersion == committedProductLoadRequestID else { continue }
            guard !Task.isCancelled else { return currentSnapshot }

            let entitlements = verifiedTransactions(from: entitlementResults)
            let pending: [PaymentPendingTransaction]
            do {
                pending = try await reconcilePendingTransactions(
                    from: unfinishedResults,
                    requiredLifecycleGeneration: requiredLifecycleGeneration
                )
            } catch is CancellationError {
                return currentSnapshot
            } catch {
                // 当前协调逻辑只会因取消而退出；保留防御分支避免未来错误覆盖旧快照。
                return currentSnapshot
            }
            if let requiredLifecycleGeneration {
                guard !Task.isCancelled,
                      isCurrentLifecycle(requiredLifecycleGeneration)
                else {
                    return currentSnapshot
                }
            }
            for failure in subscriptionResult.verificationFailures {
                reportVerificationFailure(
                    transactionID: failure.transactionID,
                    message: failure.message
                )
            }

            // 状态查询可能与购买、恢复或监听刷新交错；已提交的新响应不能被旧响应覆盖。
            guard requestID > committedStateRefreshRequestID else {
                return currentSnapshot
            }
            committedStateRefreshRequestID = requestID

            currentSnapshot = PaymentSnapshot(
                canMakePayments: canMakePayments,
                products: currentSnapshot.products,
                unavailableProductIDs: currentSnapshot.unavailableProductIDs,
                currentEntitlements: entitlements,
                subscriptionStatuses: subscriptionResult.statuses,
                pendingTransactions: pending
            )
            emit(.snapshotUpdated(currentSnapshot))
            scheduleStateBoundaryAfterSnapshotCommit(
                currentSnapshot,
                requiredLifecycleGeneration: requiredLifecycleGeneration,
                stateBoundaryContext: stateBoundaryContext
            )
            return currentSnapshot
        }
        return currentSnapshot
    }

    /// 在可靠交付完成后最佳努力刷新商品资格和支付状态。
    ///
    /// 商品资格刷新属于已完成交易后的派生状态更新。即使 App Store 暂时离线，
    /// 也不能把已经完成后台交付与 StoreKit `finish()` 的交易改写为购买失败。
    func refreshAfterProcessedTransactions(
        _ transactions: [PaymentTransaction]
    ) async -> PaymentSnapshot {
        if transactions.contains(where: {
            $0.productType == .autoRenewableSubscription
        }) {
            do {
                _ = try await reloadProducts()
                log(
                    .info,
                    category: "products",
                    message: "自动续期交易完成后已刷新订阅组首购资格"
                )
            } catch is CancellationError {
                log(
                    .debug,
                    category: "products",
                    message: "自动续期交易完成后的首购资格刷新已取消"
                )
            } catch {
                // 不记录 StoreKit 原始错误，避免错误对象意外携带账户或资格声明。
                log(
                    .warning,
                    category: "products",
                    message: "自动续期交易已完成，但首购资格暂时无法刷新"
                )
            }
        }
        return await refreshStateWithoutReloadingProducts()
    }

    func verifiedTransactions(
        from results: [StoreTransactionVerification]
    ) -> [PaymentTransaction] {
        var values: [PaymentTransaction] = []
        for result in results {
            switch result {
            case .verified(let transaction):
                storeTransactions[transaction.value.id] = transaction
                values.append(transaction.value)
            case .unverified(let transactionID, let message):
                reportVerificationFailure(transactionID: transactionID, message: message)
            }
        }
        return values
    }

    /// 合并 StoreKit 与 outbox 状态，并为已可靠交付的真实交易补做 `finish()`。
    ///
    /// 此路径只接受内存已处理状态或 outbox 已交付状态作为可靠交付证明；
    /// 普通待交付交易不会进入处理器，也不会提前结束。
    func reconcilePendingTransactions(
        from results: [StoreTransactionVerification],
        requiredLifecycleGeneration: UInt64?
    ) async throws -> [PaymentPendingTransaction] {
        var storeTransactions: [StoreTransaction] = []
        for result in results {
            switch result {
            case .verified(let transaction):
                self.storeTransactions[transaction.value.id] = transaction
                storeTransactions.append(transaction)
            case .unverified(let transactionID, let message):
                reportVerificationFailure(transactionID: transactionID, message: message)
            }
        }

        let references: Set<PendingTransactionReference>
        do {
            references = try await pendingStore.references()
        } catch {
            log(
                .error,
                category: "persistence",
                message: "读取待处理状态失败；仅使用本进程交付状态协调 finish"
            )
            references = []
        }

        var finishedCutoffs: [UInt64: Date] = [:]
        let finishCandidates = storeTransactions
            .filter(\.canFinish)
            .filter { transaction in
                processedTransactionStates.contains(transaction.value.deliveryState)
                    || references.contains {
                        $0.recordsCompletedDelivery(of: transaction.value)
                    }
            }
            .sorted { $0.value.signedDate > $1.value.signedDate }

        for transaction in finishCandidates {
            let value = transaction.value
            if let cutoff = finishedCutoffs[value.id],
               cutoff >= value.signedDate {
                continue
            }

            // 自动刷新属于客户端生命周期任务；结束交易前必须同时验证取消与 generation。
            try Task.checkCancellation()
            try checkRequiredLifecycle(requiredLifecycleGeneration)
            await gateway.finish(transaction)

            // finish 成功后清理当前及更旧签名；更晚签名可能是尚未交付的新状态。
            await removePendingReference(PendingTransactionReference(transaction: value))
            processedTransactionStates.insert(value.deliveryState)
            awaitingFinishTransactionStates.remove(value.deliveryState)
            finishedCutoffs[value.id] = value.signedDate
            emit(.transactionDelivered(value, finishState: .finished))
            log(
                .info,
                category: "transactions",
                message: "刷新取得已交付交易的真实句柄，已补 finish",
                metadata: ["transactionSuffix": transactionSuffix(value.id)]
            )
        }

        // `recoverPersistedTransactions` 可能在并发交易交付前取得 outbox fallback，
        // 随后才回到本 actor 协调最终快照。若真实 StoreKit 句柄已经完成交付、
        // finish 并清理 outbox，这个不可 finish 的旧 fallback 不得重新进入快照。
        // 重新读取持久状态，把判断点移到最终提交前；读取失败时保守沿用旧结果。
        let latestReferences: Set<PendingTransactionReference>
        do {
            latestReferences = try await pendingStore.references()
        } catch {
            latestReferences = references
        }

        return storeTransactions.compactMap { storeTransaction in
            let transaction = storeTransaction.value
            if let cutoff = finishedCutoffs[transaction.id],
               transaction.signedDate <= cutoff {
                // 同批恢复可能同时带入真实交易与旧 outbox fallback；已结束项不得残留在快照。
                return nil
            }

            if !storeTransaction.canFinish,
               processedTransactionStates.contains(transaction.deliveryState),
               !latestReferences.contains(where: { $0.matches(transaction) }) {
                // 交付期间构造的 outbox fallback 已被真实交易取代并清理；
                // 保留它会把已完成交易错误显示为 deliveredAwaitingFinish。
                return nil
            }

            // StoreKit 在 finish 后可能短暂继续返回同一笔 unfinished 交易。
            // 本进程已经完成后台交付时，不能因 outbox 已清理而降级为“等待后台交付”。
            let hasCompletedDelivery = processedTransactionStates.contains(
                transaction.deliveryState
            ) || references.contains {
                $0.recordsCompletedDelivery(of: transaction)
            }
            let state: PaymentPendingState = hasCompletedDelivery
                ? .deliveredAwaitingFinish
                : .awaitingDelivery
            return PaymentPendingTransaction(transaction: transaction, state: state)
        }
    }

    struct PersistedTransactionRecovery {
        var verifications: [StoreTransactionVerification]
        var supersededReferencesBySignedEvent: [String: Set<PendingTransactionReference>]
        var unresolvedCount: Int = 0
    }

    func recoverPersistedTransactions(
        including unfinished: [StoreTransactionVerification]
    ) async -> PersistedTransactionRecovery {
        let pendingReferences: Set<PendingTransactionReference>
        do {
            pendingReferences = try await pendingStore.references()
        } catch {
            log(
                .error,
                category: "transactions",
                message: "读取待交付交易记录失败；仅处理 StoreKit 返回的未完成交易"
            )
            return PersistedTransactionRecovery(
                verifications: unfinished,
                supersededReferencesBySignedEvent: [:],
                unresolvedCount: 1
            )
        }
        let recoveryIncidentCount = await pendingStore.consumeRecoveryIncidentCount()
        if recoveryIncidentCount > 0 {
            log(
                .error,
                category: "persistence",
                message: "已隔离损坏或未知版本的待交付记录，并将从 StoreKit 重建",
                metadata: ["incidentCount": "\(recoveryIncidentCount)"]
            )
        }
        guard !pendingReferences.isEmpty else {
            return PersistedTransactionRecovery(
                verifications: unfinished,
                supersededReferencesBySignedEvent: [:],
                unresolvedCount: recoveryIncidentCount
            )
        }

        var result = unfinished
        var includedKeys = Set(unfinished.map(verificationKey))
        let representedReferences = pendingReferences.filter { reference in
            unfinished.contains { verification in
                guard case .verified(let transaction) = verification else { return false }
                return reference.matches(transaction.value)
            }
        }
        let missingReferences = pendingReferences.subtracting(representedReferences)
        guard !missingReferences.isEmpty else {
            return PersistedTransactionRecovery(
                verifications: result,
                supersededReferencesBySignedEvent: [:],
                unresolvedCount: recoveryIncidentCount
            )
        }

        // Transaction.all 在本地 StoreKit 漏报 unfinished 时仍能提供可 finish 的原始交易。
        let history = await gateway.allTransactions()
        var supersededReferencesBySignedEvent: [String: Set<PendingTransactionReference>] = [:]
        var recoveredCount = 0
        var supersededCount = 0
        var latestFallbackCount = 0
        var outboxFallbackCount = 0
        var unresolvedCount = 0
        var queriedLatestProductIDs = Set<String>()
        var latestTransactionsByProductID: [String: StoreTransactionVerification] = [:]

        for reference in missingReferences {
            let exactMatch = history.first { verification in
                guard case .verified(let transaction) = verification else { return false }
                return reference.matches(transaction.value)
            }
            let sameTransactionMatch = history
                .compactMap { verification -> StoreTransaction? in
                    guard case .verified(let transaction) = verification,
                          transaction.value.id == reference.transactionID,
                          transaction.value.signedDate >= reference.signedDate else {
                        return nil
                    }
                    return transaction
                }
                .max { $0.value.signedDate < $1.value.signedDate }
            let unverifiedMatch = history.first { verification in
                guard case .unverified(let transactionID, _) = verification else { return false }
                return transactionID == reference.transactionID
            }
            var latestMatch: StoreTransactionVerification?
            if exactMatch == nil, sameTransactionMatch == nil, unverifiedMatch == nil {
                let candidateProductIDs = reference.productID.map { [$0] }
                    ?? configuration.productIDs
                for productID in candidateProductIDs {
                    let latest: StoreTransactionVerification?
                    if queriedLatestProductIDs.contains(productID) {
                        latest = latestTransactionsByProductID[productID]
                    } else {
                        queriedLatestProductIDs.insert(productID)
                        latest = await gateway.latestTransaction(for: productID)
                        latestTransactionsByProductID[productID] = latest
                    }
                    guard let latest,
                          verificationTransactionID(latest) == reference.transactionID else {
                        continue
                    }
                    if case .verified(let transaction) = latest,
                       transaction.value.signedDate < reference.signedDate {
                        // StoreKit 缓存可能暂时只返回旧签名；不能用它覆盖 outbox 中的新状态。
                        continue
                    }
                    latestMatch = latest
                    latestFallbackCount += 1
                    break
                }
            }

            // StoreKit 完全不可用时，同一 transaction ID 可能留下多个重新签名结果；
            // outbox 只重放签名时间最新的状态。已交付记录也必须继续保留，
            // 不能仅凭本次查询缺失就推断 finish 成功；扩展进程通常拿不到主 App 的原始句柄。
            let latestPersistedTransaction = missingReferences
                .filter { $0.transactionID == reference.transactionID }
                .compactMap(\.persistedTransaction)
                .max { $0.signedDate < $1.signedDate }
            let outboxMatch = latestPersistedTransaction.map {
                StoreTransactionVerification.verified(
                    StoreTransaction(value: $0, canFinish: false)
                )
            }

            guard let recovered = exactMatch ?? sameTransactionMatch.map({ .verified($0) })
                ?? unverifiedMatch ?? latestMatch ?? outboxMatch else {
                unresolvedCount += 1
                continue
            }
            let key = verificationKey(recovered)
            if includedKeys.insert(key).inserted {
                result.append(recovered)
                recoveredCount += 1
                if exactMatch == nil,
                   sameTransactionMatch == nil,
                   unverifiedMatch == nil,
                   latestMatch == nil,
                   outboxMatch != nil {
                    outboxFallbackCount += 1
                }
            }

            // 原签名状态已不在历史中时，以同交易 ID 的最新已验证状态为准；
            // 只有新状态成功交付后，才会删除被取代的旧索引。
            if exactMatch == nil,
               case .verified(let transaction) = recovered,
               transaction.value.signedDate >= reference.signedDate,
               !reference.matches(transaction.value) {
                supersededReferencesBySignedEvent[
                    transaction.value.signedEventIdentifier,
                    default: []
                ].insert(reference)
                supersededCount += 1
            }
        }

        if recoveredCount > 0 {
            log(
                .info,
                category: "transactions",
                message: "从持久记录找回待交付交易",
                metadata: [
                    "recoveredCount": "\(recoveredCount)",
                    "supersededCount": "\(supersededCount)",
                    "latestFallbackCount": "\(latestFallbackCount)",
                    "outboxFallbackCount": "\(outboxFallbackCount)",
                ]
            )
        }
        if unresolvedCount > 0 {
            log(
                .warning,
                category: "transactions",
                message: "部分待交付交易暂时无法从 StoreKit 找回",
                metadata: ["unresolvedCount": "\(unresolvedCount)"]
            )
        }

        return PersistedTransactionRecovery(
            verifications: result,
            supersededReferencesBySignedEvent: supersededReferencesBySignedEvent,
            unresolvedCount: unresolvedCount + recoveryIncidentCount
        )
    }

    func isPersistedAsDelivered(_ verification: StoreTransactionVerification) async -> Bool {
        guard case .verified(let transaction) = verification else { return false }
        do {
            return try await pendingStore.references().contains {
                $0.recordsCompletedDelivery(of: transaction.value)
            }
        } catch {
            return false
        }
    }

    func verificationCanFinish(_ verification: StoreTransactionVerification) -> Bool {
        guard case .verified(let transaction) = verification else { return false }
        return transaction.canFinish
    }

    func persistenceError(
        for transaction: PaymentTransaction,
        operation: String
    ) -> PaymentError {
        PaymentError(
            code: .persistenceFailed,
            message: "\(operation)失败；交易保持未完成",
            productID: transaction.productID,
            transactionID: transaction.id
        )
    }

    func verificationKey(_ verification: StoreTransactionVerification) -> String {
        switch verification {
        case .verified(let transaction):
            return "verified|\(transaction.value.signedEventIdentifier)"
        case .unverified(let transactionID, let message):
            return "unverified|\(transactionID.map(String.init) ?? "unknown")|\(message)"
        }
    }

    func verificationTransactionID(
        _ verification: StoreTransactionVerification
    ) -> UInt64? {
        switch verification {
        case .verified(let transaction):
            return transaction.value.id
        case .unverified(let transactionID, _):
            return transactionID
        }
    }

    func removePendingReference(_ reference: PendingTransactionReference) async {
        do {
            // finish 成功后清理当前及更旧签名；更晚签名可能携带新状态，不能误删。
            try await pendingStore.removeCurrentAndOlder(reference)
            removePendingReferenceFromSnapshot(reference)
        } catch {
            log(
                .warning,
                category: "transactions",
                message: "待交付交易记录清理失败，将在下次启动幂等重放",
                metadata: ["transactionSuffix": transactionSuffix(reference.transactionID)]
            )
        }
    }

    /// outbox 清理成功后同步收敛内存快照，避免交易监听的派生刷新被短命
    /// StoreKit 流取消时，界面继续显示已经 finish 的 pending 记录。
    func removePendingReferenceFromSnapshot(
        _ reference: PendingTransactionReference
    ) {
        let finishedDeliveryState = reference.persistedTransaction?.deliveryState
        let remaining = currentSnapshot.pendingTransactions.filter { pending in
            let candidate = PendingTransactionReference(
                transaction: pending.transaction
            )
            guard candidate.transactionID == reference.transactionID else {
                return true
            }

            // StoreKit 的多个查询入口可能为同一业务状态返回不同 signedDate/JWS。
            // finish 较旧句柄已经结束该业务状态；快照中的较新等价重签名也必须移除。
            // 撤销、升级、到期等真实状态变化具有不同 deliveryState，仍按时间保留。
            if let finishedDeliveryState,
               candidate.persistedTransaction?.deliveryState == finishedDeliveryState {
                return false
            }
            return candidate != reference
                && candidate.signedDate >= reference.signedDate
        }
        guard remaining.count != currentSnapshot.pendingTransactions.count else {
            return
        }

        currentSnapshot = PaymentSnapshot(
            canMakePayments: currentSnapshot.canMakePayments,
            products: currentSnapshot.products,
            unavailableProductIDs: currentSnapshot.unavailableProductIDs,
            currentEntitlements: currentSnapshot.currentEntitlements,
            subscriptionStatuses: currentSnapshot.subscriptionStatuses,
            pendingTransactions: remaining
        )
        emit(.snapshotUpdated(currentSnapshot))
    }

    func removeSupersededReferences(
        _ references: Set<PendingTransactionReference>
    ) async {
        for reference in references {
            await removePendingReference(reference)
        }
    }

    func reportVerificationFailure(transactionID: UInt64?, message _: String) {
        emit(
            .verificationFailed(
                transactionID: transactionID,
                message: "StoreKit 数据验签失败"
            )
        )
        var metadata: [String: String] = [:]
        if let transactionID {
            metadata["transactionSuffix"] = transactionSuffix(transactionID)
        }
        log(.error, category: "verification", message: "StoreKit 数据验签失败", metadata: metadata)
    }

    func emit(_ event: PaymentEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    func removePurchaseIntentContinuation(_ id: UUID) {
        purchaseIntentContinuations[id] = nil
    }

    func finishPurchaseIntentContinuations() {
        for continuation in purchaseIntentContinuations.values {
            continuation.finish()
        }
        purchaseIntentContinuations.removeAll()
    }

    func removeStoreMessageContinuation(_ id: UUID) {
        storeMessageContinuations[id] = nil
    }

    func finishStoreMessageContinuations() {
        for continuation in storeMessageContinuations.values {
            continuation.finish()
        }
        storeMessageContinuations.removeAll()
    }

    func log(
        _ level: PaymentLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        logger.log(
            PaymentLogEntry(
                level: level,
                category: category,
                message: message,
                metadata: metadata
            )
        )
    }

    func mapStoreError(
        _ error: any Error,
        operation: String,
        productID: String? = nil
    ) -> PaymentError {
        mapStoreFailure(
            error,
            operation: operation,
            productID: productID
        ).error
    }

    func mapStoreFailure(
        _ error: any Error,
        operation: String,
        productID: String? = nil
    ) -> MappedStoreError {
        if let paymentError = error as? PaymentError {
            return MappedStoreError(error: paymentError, metadata: [:])
        }

        guard let storeKitError = error as? StoreKitError else {
            return MappedStoreError(
                error: PaymentError(
                    code: .storeKitFailed,
                    message: "\(operation)失败",
                    productID: productID
                ),
                metadata: ["storeKitError": "other"]
            )
        }

        let category: String
        let message: String
        var metadata: [String: String]

        if #available(iOS 18.4, macOS 15.4, *),
           case .unsupported = storeKitError {
            category = "unsupported"
            message = "\(operation)失败：当前系统不支持此操作"
            metadata = ["storeKitError": category]
        } else if #available(iOS 15.4, macOS 12.3, *),
                  case .notEntitled = storeKitError {
            category = "notEntitled"
            message = "\(operation)失败：当前账户或应用无权执行此操作"
            metadata = ["storeKitError": category]
        } else {
            switch storeKitError {
            case .unknown:
                category = "unknown"
                message = "\(operation)失败：App Store 返回未知错误"
                metadata = ["storeKitError": category]
            case .userCancelled:
                category = "userCancelled"
                message = "\(operation)已取消"
                metadata = ["storeKitError": category]
            case .networkError(let urlError):
                category = "network"
                message = "\(operation)失败：App Store 网络错误（\(urlError.errorCode)）"
                metadata = [
                    "storeKitError": category,
                    "urlErrorCode": String(urlError.errorCode),
                ]
            case .systemError(let underlyingError):
                let nsError = underlyingError as NSError
                category = "system"
                message = "\(operation)失败：App Store 系统错误（\(nsError.domain) \(nsError.code)）"
                metadata = [
                    "storeKitError": category,
                    "underlyingErrorDomain": nsError.domain,
                    "underlyingErrorCode": String(nsError.code),
                ]
            case .notAvailableInStorefront:
                category = "storefront"
                message = "\(operation)失败：当前 App Store 地区不可用"
                metadata = ["storeKitError": category]
            default:
                category = "unknown"
                message = "\(operation)失败：App Store 返回未知错误"
                metadata = ["storeKitError": category]
            }
        }

        return MappedStoreError(
            error: PaymentError(
                code: .storeKitFailed,
                message: message,
                productID: productID
            ),
            metadata: metadata
        )
    }

    func transactionSuffix(_ id: UInt64) -> String {
        String(String(id).suffix(6))
    }

    func durationMilliseconds(since start: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= start ? (now - start) / 1_000_000 : 0
    }
}

/// 生命周期监听任务只保留此弱引用，避免在等待无限异步序列时保活客户端。
private final class WeakPaymentClientReference: @unchecked Sendable {
    weak var value: PaymentClient?

    init(_ value: PaymentClient) {
        self.value = value
    }
}
