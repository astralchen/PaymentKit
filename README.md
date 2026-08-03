# PaymentKit

PaymentKit 是基于 StoreKit 2 的中立内购框架，支持 iOS 15+、macOS 13+ 和 Swift 6 严格并发。框架不依赖第三方库，也不包含会员等级、金币余额、商品分组、展示策略或权益持久化等业务规则。

框架覆盖：

- 消耗型、非消耗型、非续期订阅和自动续期订阅
- 商品加载与无效商品 ID 报告
- 购买、恢复、未完成交易重试和当前权益查询
- 自动续期订阅状态与续订信息
- 自动续期订阅多定价方案与月付承诺计划
- 首购、促销、优惠代码和回归用户优惠
- App Store 外部购买意图与按需接管的系统消息
- `Transaction.updates` 持续监听、签名事件去重和跨启动失败重放
- SQLite 回滚日志 outbox 与 App Group 多进程协调
- iOS/macOS 退款入口，以及 iOS 订阅管理入口
- 结构化统一日志与自定义日志处理器

## 接入

在 Xcode 中选择 **File > Add Package Dependencies**，添加本地目录或仓库地址，然后让应用 Target 链接 `PaymentKit`。

实现一个可跨启动幂等的交易处理器：

```swift
import PaymentKit

actor AppTransactionProcessor: TransactionProcessor {
    func process(_ transaction: PaymentTransaction) async throws {
        // 把 transaction.jwsRepresentation 发送到生产后台。
        // 后台独立验签并完成幂等交付后才能正常返回。
    }
}
```

创建客户端并在应用启动时尽早调用 `start()`：

```swift
let client = PaymentClient(
    configuration: PaymentConfiguration(
        productIDs: ["com.example.product"]
    ),
    processor: AppTransactionProcessor()
)

await client.start()
```

`start()` 会先建立 [`Transaction.updates`](https://developer.apple.com/documentation/storekit/transaction/updates) 监听，再重放 unfinished 交易并刷新商品和状态。重复调用是安全的。应用不再需要监听时可调用 `stop()`。

## 自动刷新契约

调用 `start()` 后，PaymentKit 会从以下六类来源自动收敛商品、权益、订阅状态和
pending 交易，正常流程不要求用户点击刷新：

1. **交易更新**：普通购买、PurchaseIntent、Ask to Buy 批准、自动续订、退款撤销、
   优惠代码及其他 `Transaction.updates` 交易触发状态刷新；可靠交付仍严格经过
   SQLite outbox 和 `TransactionProcessor`。
2. **应用回到前台**：iOS `UIApplication.didBecomeActiveNotification` 或 macOS
   `NSApplication.didBecomeActiveNotification` 先重放 StoreKit/持久 outbox 中新发现的
   unfinished 交易，再触发完整刷新，以同步应用在后台期间发生的账户、续订偏好、
   价格同意和家庭共享变化。该重放仍严格遵守“先落盘、后台幂等交付、标记完成、
   最后 `finish()`”的顺序。
3. **Storefront 更新**：`Storefront.updates` 触发完整刷新，重新加载当前商店的价格、
   币种、商品可用性和优惠元数据。
4. **订阅时间边界**：交易到期、预计续订、账单宽限期结束和月付承诺续订日期到达后，
   触发轻量状态刷新。若 StoreKit 暂时返回跨过边界的旧状态，框架按 1、2、5、15 秒
   有限退避收敛；次数用尽即停止，等待下一项真实事件，不进行固定轮询。
5. **StoreKit 系统界面返回**：示例在订阅管理、优惠代码兑换、退款请求和已接管的
   Store Message 返回后，依次重放 unfinished、完整刷新并读取模拟后台状态。交易本身
   仍由 `Transaction.updates` 进入可靠交付链路。
6. **后台恢复信号**：示例把模拟后台由离线或故障切回正常时，会自动调用
   `retryUnfinishedTransactions()`，不依赖诊断刷新、重试按钮、前后台切换或应用重启。
   真实 App 应在自己的网络、登录会话或后台健康状态恢复后发出等价信号；PaymentKit
   不轮询业务服务器，也不把网络可达误当作业务交付成功。

短时间内同时到达的前台、Storefront、交易和时间边界触发会被合并；完整刷新优先于
轻量刷新。刷新期间到达的新触发会在本轮结束后再执行一次，避免漏掉并发变化。自动
刷新失败会保留最后一个完整快照，并等待下一次触发重试，不会结束尚未可靠交付的交易。

`stop()` 会取消当前生命周期的交易、应用活动、Storefront、PurchaseIntent、已启用的
Store Message 和订阅边界监听，同时取消待执行的合并刷新及在途任务。旧生命周期在
取消后不得重新建立监听、提交快照或调用 `finish()`；再次调用 `start()` 会建立新的
独立生命周期。

自动刷新路径不会调用 `AppStore.sync()`。只有用户明确点击“恢复购买”并调用
`restorePurchases()` 时才允许触发系统同步和可能的认证界面。

前台重放与普通诊断刷新有意不同：`refresh()` 只汇总未完成交易，不能主动执行新的
业务交付；应用活动触发的受生命周期约束批次则会先消费 newly-discovered unfinished，
避免账号切换或系统页返回后界面长期停留在“等待后台交付”。短时间重复进入前台时，
同一交易状态只会命中一次业务处理器，已经交付的状态只补 `finish()`，不会重复交付。

Apple 账户可能在 App 外部切换，StoreKit 没有公开的账户切换通知。普通前台刷新不能
保证识别账户边界。应用在管理订阅、优惠代码兑换等已知 StoreKit 系统流程返回后，
可以无认证地热重载 StoreKit 会话：

```swift
let snapshot = await client.reloadStoreSession()
```

`reloadStoreSession()` 不退出进程。它停止旧生命周期、清除会话级订阅事件缓存、重建
StoreKit 异步序列，并重新加载商品、权益、订阅状态和 unfinished 交易。SQLite outbox
和最近已验证快照不会被清空；离线或弱网时保留旧快照。该方法不会调用
`AppStore.sync()`，也不会主动弹出账户认证。不要在每次进入前台时无条件调用。

真机上，完全发生在 App 外的 Apple/Sandbox 账户切换可能连
`Transaction.currentEntitlements` 都继续返回旧账户状态；仅重建异步序列无法强制
StoreKit 切换账户。此时必须由用户明确点击“恢复购买”：

```swift
let snapshot = try await client.restorePurchases()
```

`restorePurchases()` 调用 `AppStore.sync()`；同步成功后停止旧会话、清除会话级
订阅事件和原始交易缓存、重建长期监听与 outbox 重放，再执行受新生命周期约束的完整
刷新。同步失败不会停止旧会话或清空最后有效快照。不要在启动、前台通知、定时器或
系统页返回时自动调用该方法，因为 Apple 明确规定 `AppStore.sync()` 只能响应用户
操作，并且可能显示账户认证界面。

系统订阅页与 App 的 `willAutoRenew` 长时间不一致时，不得根据系统页往返猜测状态，
也不得用月付承诺计划的内层字段覆盖普通订阅的外层字段。完整的字段判定矩阵、
2026-07-30 真机 Sandbox 陈旧签名快照根因、客户端兜底与生产服务器方案见
[`willAutoRenew` 语义、陈旧状态与生产级收敛](docs/will-auto-renew-troubleshooting.md)。

`PaymentEvent` 只用于界面和诊断，不是可靠交付队列。应用可以订阅
`.snapshotUpdated` 更新界面，但即使没有订阅者，已验证交易仍会通过
`TransactionProcessor` 与 SQLite outbox 可靠处理。示例右上角的刷新按钮仅用于人工
诊断网络或 App Store Connect 配置，不是购买、恢复、订阅管理或任何验收流程的前置
步骤。

后台恢复触发也不直接修改 SQLite。示例只提交最新故障配置，并把可靠重试交给
`PaymentClient`；快速连续切换时会取消旧任务，并用单调 revision 阻止旧结果覆盖最新
界面状态。交易仍严格遵循“outbox 落盘 → 后台幂等交付 → 标记已交付 → StoreKit
`finish()` → 清理”的顺序。

某些本地 StoreKit 测试环境会在应用重启后暂时漏报 `Transaction.unfinished`，甚至同时漏报 `Transaction.all`。PaymentKit 会在调用处理器前，把已经通过 StoreKit 本地验证的中立交易快照写入 SQLite；启动时依次通过 `Transaction.unfinished`、`Transaction.all`、`Transaction.latest(for:)` 和持久 outbox 补偿。

outbox 为了能够重新提交后台验签，会临时保存 JWS 和 `appAccountToken`，但不保存会员、余额或任何业务权益。生产存储直接使用系统 `SQLite3`，固定为回滚日志 `journal_mode=DELETE`、`synchronous=EXTRA`、`secure_delete=ON`、短连接和短事务；不使用 WAL。数据库上限为 8 MiB、最多 1,000 条记录、单条载荷最多 256 KiB。每个短连接都会强制启用并验证 `secure_delete`，因此交易清理时会覆写 SQLite B-tree 中已删除的敏感载荷；启用失败时存储会失败关闭，交易不会被提前 `finish()`。

每次存储操作都先在独立锁文件上尝试 `flock(LOCK_EX | LOCK_NB)`，每 50 ms 检查取消，最多等待 5 秒；取得锁后才打开 SQLite 连接。应用被强制结束时，内核会自动释放进程持有的文件锁。两个进程可能在后台调用窗口内提交同一签名事件，因此 `TransactionProcessor` 仍必须实现远端幂等，SQLite 不会把至少一次交付错误地包装成恰好一次交付。

数据库目录、锁文件、数据库和回滚日志使用 POSIX `0700/0600`，排除设备备份；iOS 使用“首次解锁后可访问”的 Data Protection。每次打开会执行 `quick_check(1)`，并验证当前版本的完整建表语句、约束、`WITHOUT ROWID` 和固定索引。损坏、错误 header、完整性检查失败或当前版本 schema 不匹配的数据库及 sidecar 会整组移入受限隔离区，再由 StoreKit 重建；最多保留 3 组且总计不超过 32 MiB。高于当前 `user_version` 的数据库不会被破坏或降级，而是明确失败并让 StoreKit 交易保持 unfinished。任何 v1 DDL 变更都必须同步提升 `user_version`。`secure_delete` 只能保证启用后的删除操作；若开发设备曾运行未启用该选项的旧调试构建，应在验收新构建前卸载示例并清理 App Group 测试数据，不能把旧 SQLite 空闲页扫描结果误认为新实现产生。

### App Group 多进程存储

不传 `storage` 时默认使用当前应用容器：

```swift
let client = PaymentClient(
    configuration: configuration,
    processor: processor
)
```

主应用和扩展共同处理 outbox 时，两边必须签入同一个 App Group，并传入完全相同的 identifier、namespace 和 PaymentKit 版本：

```swift
let client = try PaymentClient(
    configuration: configuration,
    processor: processor,
    storage: .appGroup(
        identifier: "group.com.example.app",
        namespace: "com.example.app.payment-outbox"
    )
)
```

namespace 会先计算 SHA-256 再作为目录名，不会直接进入文件路径。App Group 容器不可访问、identifier 为空或 namespace 为空时，初始化立即抛出 `.invalidConfiguration`，不会静默回退到应用容器。

## 可靠交付契约

PaymentKit 只把当前进程本地验签成功，或先前已验签并由框架 outbox 原样保存的交易传给 `TransactionProcessor`。可靠交付顺序固定为：写入待交付记录 → 调用处理器 → 持久标记已交付 → 调用 `Transaction.finish()` → 清理记录。任何持久化步骤失败都不会提前 `finish()`。

如果 Xcode 本地 StoreKit 在重启后不再提供任何可 `finish()` 的原始交易句柄，PaymentKit 仍会从 outbox 完成后台交付，并把记录标记为“已交付、等待 finish”；同一进程不会重复调用后台。原始交易以后通过 StoreKit 重新出现时，框架只补做 `finish()`。这是 StoreKit 2 公共 API 的边界，框架不会为测试环境偷偷引入 StoreKit 1 或在启动时调用 `AppStore.sync()`。

处理器仍必须支持跨启动幂等。应用可能在“后台已经成功，但已交付标记尚未落盘”之间崩溃，下一次启动会再次提交同一交易；StoreKit 还可能为未变化的交易状态生成新的 JWS 和签名时间。生产后台应独立验证 JWS，并分别维护“签名事件审计幂等”和“业务交付幂等”，不能把 JWS 摘要作为唯一的业务交付键。相同 transaction ID 的重新签名不应重复发放权益，但撤销、到期、升级或所有权变化等新状态仍应再次处理。

恢复同一 transaction ID 时，StoreKit history 或 `latest(for:)` 候选的 `signedDate` 不得早于 outbox 记录。StoreKit 暂时只返回旧签名时，PaymentKit 会保留并处理 outbox 中较新的撤销、升级或所有权状态，不会把新状态标记为 superseded 或随旧状态一起删除。

交易更新以最多 4 笔受控并发处理，单笔慢请求不会阻塞后续不同订单。`stop()` 会同时取消监听、启动阶段的 outbox 重放和在途任务；已停止生命周期不能再提交交付状态或执行 `finish()`。监听序列意外结束时会按上限 4 秒的指数退避重新建立。新更新流建立后、开始消费前，框架会主动重放 unfinished 与持久 outbox，避免上一批次被取消的订单只能等待下一次 StoreKit update 或应用重启。重连日志只报告重放尝试数、失败数和剩余积压数。

`PaymentEvent.transactionDelivered(_:finishState:)` 会通过 `.finished` 或 `.awaitingStoreKit` 准确报告结束状态。事件只适合刷新界面和诊断，不承担可靠交付；即使没有事件订阅者，`TransactionProcessor` 仍会被调用。

## 购买与恢复

购买前先启动客户端或显式调用 `reloadProducts()`：

```swift
let products = try await client.reloadProducts()
let outcome = try await client.purchase(productID: products[0].id)

switch outcome {
case .completed(let transaction):
    print("已交付：\(transaction.productID)")
case .pending:
    print("等待 Ask to Buy 或其他外部批准")
case .cancelled:
    print("用户取消")
}
```

无效商品 ID 会被 StoreKit 静默排除。PaymentKit 允许部分加载成功，并把缺失项放入 `PaymentSnapshot.unavailableProductIDs`。

### 订阅定价方案

`PaymentProduct.subscription.pricingTerms` 返回 StoreKit 对当前 storefront 提供的全部
定价方案。iOS 26.4/macOS 26.4 以前，传统订阅会被表示为一项 `.upFront` 条款；
新系统还可以返回 `.monthlyCommitment`：

```swift
for terms in subscription.pricingTerms {
    switch terms.billingPlan {
    case .upFront:
        // 展示 terms.commitment.displayPrice 和完整订阅周期。
        break
    case .monthlyCommitment:
        // 确认购买前必须同时展示每月价格、承诺总价和完整承诺期限。
        show(
            monthly: terms.billingDisplayPrice,
            total: terms.commitment.displayPrice,
            duration: terms.commitment.period
        )
    case .unknown(let rawValue):
        recordUnknownBillingPlan(rawValue)
    }
}
```

购买时选择商品实际返回的方案；框架会拒绝未知方案、目标商品不存在的方案，以及不
属于所选方案的优惠：

```swift
let outcome = try await client.purchase(
    productID: product.id,
    options: PurchaseOptions(billingPlan: .monthlyCommitment)
)
```

月付承诺计划只在 iOS 26.4/macOS 26.4 及更高版本映射为
`Product.PurchaseOption.billingPlanType(.monthly)`；旧系统返回
`.unsupportedFeature`，不会静默降级到年付。

月付承诺有两个不同层级的续订状态，接入方必须分别展示：

- `PaymentTransaction.commitment.billingPeriodNumber` 与
  `totalBillingPeriods` 描述当前承诺已经完成的分期和仍需履行的分期；
- 外层 `PaymentRenewalInfo.willAutoRenew` 描述 StoreKit 当前报告的下一账期续订
  状态。普通预付月/年订阅只读取这一层；
- `PaymentRenewalInfo.commitment?.willAutoRenew` 描述当前承诺结束后是否开始新的
  完整承诺，且只适用于 `billingPlanType == .monthly` 的月付承诺计划。

因此，用户取消月付承诺后，当前承诺尚未完成的分期仍会继续扣款，而
外层 `willAutoRenew` 仍为 `true`，内层 `commitment?.willAutoRenew` 为 `false`，
表示月度账单继续但不会开始下一轮完整承诺。界面不得把
“下一承诺已取消”误报为“当前剩余分期停止”，也不得仅凭 `willAutoRenew` 推断剩余
分期数。示例会组合交易承诺进度与续订信息，分别显示“当前承诺：剩余 N 期继续按月
付款”“下一承诺：已取消”和“承诺进度：第 x/y 期”；完成第 y 期后显示“当前承诺：
全部分期已完成”。

普通预付年订阅关闭自动续订时，外层 `willAutoRenew` 必须为 `false`，但当前已付款
权益仍保留到 `expirationDate`。完整判定、Sandbox 陈旧状态诊断和服务器通知/API
收敛规则见
[`willAutoRenew` 专题文档](docs/will-auto-renew-troubleshooting.md)。

### 首购优惠

`PaymentSubscriptionInfo` 同时提供 `introductoryOffer` 和
`isEligibleForIntroductoryOffer`。只有“商品存在首购优惠”且“当前 Apple 账户有
资格”同时成立时，界面才能显示可购买优惠：

```swift
if let subscription = product.subscription,
   let offer = subscription.introductoryOffer,
   subscription.isEligibleForIntroductoryOffer {
    // 展示 offer.paymentMode、offer.period、offer.displayPrice，
    // 同时展示商品或定价条款的标准续订价格。
}
```

Apple 的资格布尔值描述账户历史，不代表商品一定配置了优惠。首购资格以订阅组为
单位；同组月订阅已经使用首购优惠后，不能再对年订阅重复使用。PaymentKit 会在
自动续期交易完成、交易监听处理或 unfinished 重放后，最佳努力重新加载整组商品
资格；刷新暂时失败不会把已经交付并 finish 的购买改成失败。

使用 Apple 本机资格且当前定价方案配置了首购优惠时，StoreKit 会在购买时应用该
优惠。界面不得同时提供一个无法兑现的“标准价格”退出选项，也不得用标准价格作为
按钮文案；购买前必须展示优惠期价格、优惠周期以及优惠结束后的标准续订价格，使
应用界面与 App Store 确认页一致。只有账户不符合资格，或当前定价方案没有首购
优惠时，标准价格才是可选购买方案。

默认使用 Apple 本机资格：

```swift
let options = PurchaseOptions(
    offer: .introductory(eligibility: nil)
)
```

生产后台也可以按应用账户策略签发 Apple 要求的 compact JWS：

```swift
let eligibility = PaymentIntroductoryOfferEligibility(
    compactJWS: compactJWSFromProductionBackend
)
let outcome = try await client.purchase(
    productID: "com.example.subscription.monthly",
    options: PurchaseOptions(
        appAccountToken: accountToken,
        offer: .introductory(eligibility: eligibility)
    )
)
```

PaymentKit 只检查 JWS 由三个非空 compact serialization 段组成，并验证商品确实
配置首购优惠。框架不解析载荷、不信任客户端声明、不请求资格服务；StoreKit 负责
最终验证 Apple 签名、账户和 storefront 条件。

### 促销优惠

生产后台取得 App Store Connect In-App Purchase Key 后，为指定商品和促销
offer ID 生成短期 ES256 compact JWS。客户端只在内存中透传：

```swift
let authorization = PaymentPromotionalOfferAuthorization(
    offerID: "retention_offer",
    compactJWS: compactJWSFromProductionBackend
)
let outcome = try await client.purchase(
    productID: product.id,
    options: PurchaseOptions(
        offer: .promotional(authorization: authorization)
    )
)
```

框架会在调用 StoreKit 前检查三段 JWS 外形，并确认目标商品确实包含同 ID 的促销
优惠；不解析或自行验证载荷。格式错误抛出 `.offerAuthorizationInvalid`，ID 不匹配
抛出 `.offerNotFound`。真正生产环境必须由受控后台签发，不能把私钥或签名逻辑放进
应用。

### 回归用户优惠与外部购买意图

`subscription.winBackOffers` 是商品配置列表，不等于当前账户资格。可购买集合必须
按 Apple 返回的优先级使用 `PaymentRenewalInfo.eligibleWinBackOfferIDs` 与商品
优惠 ID 交叉匹配：

```swift
let eligibleIDs = status.renewalInfo.eligibleWinBackOfferIDs
let eligibleOffers = subscription.winBackOffers.filter { offer in
    offer.id.map(eligibleIDs.contains) == true
}
```

应用主动购买回归优惠时传入 `.winBack(offerID:)`；框架会同时校验配置和当前资格。
iOS 18+/macOS 15+ 支持 StoreKit 回归优惠购买，旧系统返回
`.unsupportedFeature`。

App Store 也可以从推广页或系统回归优惠入口创建外部购买意图。`start()` 会建立并
自动重连该监听，调用方可先登录或展示说明，再接受或放弃：

```swift
for await intent in await client.purchaseIntents() {
    if shouldAccept(intent) {
        // 接受时必须传回当前 PaymentClient 收到的原始 intent。
        let outcome = try await client.purchase(
            intent: intent,
            options: PurchaseOptions(appAccountToken: accountToken)
        )
        handle(outcome)
    } else {
        // 真正从客户端待处理集合移除；重复放弃会返回 false。
        client.discardPurchaseIntent(intent)
    }
}
```

从 `PaymentPurchaseIntent` 携带的回归优惠来自 App Store 当前上下文，接受时不依赖
可能已经过期的本地资格缓存。普通外部购买同样直接使用 intent 携带的原始商品，
不会重新按 ID 使用可能过期的商品缓存。`discardPurchaseIntent(_:)` 只删除仍精确
匹配的待处理 intent；`stop()` 会清空旧生命周期的 intent，StoreKit 可在下次启动
重新投递。iOS 16.4/macOS 14.4 以下不会建立监听或重连，公开异步流会正常结束。

### 优惠代码

优惠代码不能作为普通 `PurchaseOptions` 叠加购买，只能使用系统兑换入口。iOS
16+ 使用 StoreKit 2 场景 API；iOS 15 只用 StoreKit 1 展示兑换页，交易监听与可靠
处理仍完全使用 StoreKit 2。macOS 15+ 支持兑换页，macOS 13–14 返回
`.unsupportedFeature`：

```swift
try await PaymentPresentation.presentOfferCodeRedeemSheet(in: windowScene)
```

无论代码从应用内页面还是 App Store 外部兑换，最终交易都会进入同一
`Transaction.updates`、SQLite outbox 和幂等处理链路。

### 实际优惠与 StoreKit 系统消息

`PaymentTransaction.appliedOffer` 和 `PaymentRenewalInfo.appliedOffer` 可区分首购、
促销、优惠代码、回归优惠及未知未来类型，并保留付款方式和周期；交易和续订同时
提供账单计划与承诺进度快照。outbox 会保存这些中立元数据用于重启恢复，但价格、
优惠和账单元数据不参与业务交付摘要。

默认情况下 PaymentKit 不消费 `Message.messages`，StoreKit 继续自动展示价格同意、
账单问题和回归优惠等系统消息。只有确实需要控制展示时机时才调用：

```swift
for await message in await client.storeMessages() {
    // iOS 16+；调用方必须展示或明确放弃每条已经接管的消息。
    try PaymentPresentation.displayStoreMessage(message, in: windowScene)
}
```

Store Message 监听意外结束时会按 250 ms 至 4 s 退避重新建立；`stop()` 后旧生命周期
不能继续重连或发出消息。不支持 Store Message 的平台不会消费系统序列，公开流会
正常结束，因此 StoreKit 的默认展示行为不受影响。

完整资格/促销 JWS、私钥和 `appAccountToken` 不进入 `PaymentEvent`、日志或 SQLite
outbox 的优惠配置字段；交易处理所必需的 Apple 交易 JWS 只存在于受保护的 outbox
payload，并遵循前述可靠交付生命周期。

只有明确的用户操作才能调用：

```swift
let snapshot = try await client.restorePurchases()
```

该方法会调用 [`AppStore.sync()`](https://developer.apple.com/documentation/storekit/appstore/sync%28%29)，可能展示系统认证界面；框架启动时不会自动触发恢复认证。

`PaymentSnapshot.pendingTransactions` 使用 `PaymentPendingState.awaitingDelivery` 和 `.deliveredAwaitingFinish` 区分后台交付阶段。手动重试会返回统计报告：

```swift
let report = await client.retryUnfinishedTransactions()
print(report.deliveredCount, report.finishedCount, report.awaitingFinishCount)
```

`PaymentPendingTransaction.id` 是签名事件的不透明 identity。当前实现为固定 64 字符小写十六进制 SHA-256 摘要；调用方不得解析或持久依赖其内部格式。该值不包含 JWS 原文，并会在 transaction ID、签名时间或 JWS 变化时改变。

## 结果与错误语义

用户取消购买返回 `PurchaseOutcome.cancelled`，Ask to Buy 等待批准返回 `.pending`，两者都不是错误。真正失败时抛出带稳定 `PaymentErrorCode` 的 `PaymentError`：

- `invalidQuantity`、`invalidPurchaseOptions`、`productNotFound`、`purchasesNotAllowed`
  表示调用前置条件不满足；
- `billingPlanUnavailable` 表示商品或所选定价条款不支持请求的账单计划；
- `offerNotFound`、`offerNotEligible` 表示优惠未配置、与账单计划不匹配或当前账户
  不具备资格；
- `offerAuthorizationInvalid` 表示促销 compact JWS 外形无效；
- `unsupportedFeature` 表示当前系统版本没有所请求的回归优惠、承诺计划或系统界面；
- `verificationFailed` 表示 StoreKit 本地验签失败，交易不会交给处理器；
- `processingFailed` 表示后台处理器失败，交易保持 unfinished；
- `persistenceFailed` 表示可靠交付状态不能安全落盘，交易不会 finish；
- `recoveryFailed` 表示旧持久记录不能恢复为可处理交易；
- `storeKitFailed` 表示 StoreKit 操作失败；
- `presentationUnavailable` 表示当前没有可展示系统界面的场景或控制器。

任务取消会原样抛出 `CancellationError`，不会包装成 `PaymentError`，也不会提交部分状态快照或结束尚未可靠交付的交易。

## 权益边界

`PaymentSnapshot.currentEntitlements` 只包含 StoreKit 已验证记录。PaymentKit：

- 不计算消耗品余额；
- 不定义非续期订阅有效期；
- 不把商品映射为会员等级或功能开关；
- 不持久化业务权益。

业务层应根据自己的服务器记录定义这些规则。StoreKit 的 [`currentEntitlements`](https://developer.apple.com/documentation/storekit/transaction/currententitlements) 序列也可能包含已结束的非续期订阅，不能直接当作业务有效期。

## 日志

默认 `OSPaymentLogHandler` 使用 Apple Unified Logging 输出生命周期、商品加载、购买、验签、交易处理、恢复、退款和订阅管理日志：

```swift
let client = PaymentClient(
    configuration: configuration,
    processor: processor,
    logger: OSPaymentLogHandler(
        subsystem: "com.example.app",
        category: "Payments"
    )
)
```

也可以实现 `PaymentLogHandler` 接入自己的诊断系统，或用 `DisabledPaymentLogHandler` 关闭输出。交易日志包含阶段、耗时、积压数量和交易 ID 后六位，但不会写入 JWS、`appAccountToken`、完整交易 ID 或任意底层错误描述。

## API 迁移

可靠性状态 API 有以下不兼容调整：

- `PaymentSnapshot.unfinishedTransactions` 改为 `pendingTransactions: [PaymentPendingTransaction]`；
- `PaymentEvent.transactionProcessed` 改为 `transactionDelivered(_:finishState:)`；
- `retryUnfinishedTransactions()` 现在返回 `PaymentRetryReport`，不需要报告时可以忽略返回值。
- 测试 SPI 参数 `pendingTransactionsFileURL` 改为 `pendingTransactionsDatabaseURL`。
- `PaymentPendingTransaction.id` 仍为 `String`，但值改为不透明签名事件摘要；禁止按旧分隔格式解析。
- 原试验性的 `PurchaseOptions.introductoryOfferEligibility` 已整理为互斥的
  `PurchaseOptions.offer`；首购、促销和回归优惠不能在同一次购买中叠加。
- 订阅展示应优先读取 `pricingTerms`，并把 `PaymentBillingPlan.unknown` 和
  `PaymentSubscriptionOffer.typeRawValue` 当作前向兼容数据。

框架尚未发布，因此不会迁移旧 `pending-transactions-v1.json`。开发构建升级前应卸载示例或手动清理旧数据；生产发布前如果已有自定义分支使用 JSON，接入方必须先自行设计迁移。迁移后不要把“后台已交付、等待 StoreKit”显示成后台失败，也不要依赖事件流完成业务交付。

## 系统界面

iOS 使用当前 `UIWindowScene`：

```swift
try await PaymentPresentation.beginRefund(for: transactionID, in: windowScene)
try await PaymentPresentation.showManageSubscriptions(in: windowScene)
```

macOS 使用承载界面的 `NSViewController` 请求退款：

```swift
try await PaymentPresentation.beginRefund(for: transactionID, in: viewController)
```

StoreKit 没有等价的 macOS `showManageSubscriptions` 场景 API，因此 PaymentKit 不提供伪造接口。

## 示例和本地 StoreKit 测试

[Examples.xcodeproj](Examples/Examples.xcodeproj) 已链接本地 Package。共享 `Examples` Scheme 默认启用 [PaymentKit.storekit](Examples/PaymentKit.storekit)，包含：

- `paymentkit.demo.coins100`：消耗型，中国大陆价格 `¥8`
- `paymentkit.demo.lifetime`：非消耗型，中国大陆价格 `¥8`
- `paymentkit.demo.monthly`：月度自动续期订阅，中国大陆标准价 `¥22/月`，包含
  7 天免费试用和 `pk_monthly_promo_099_2m_2026` 的 `¥8/月 × 2` 按期促销优惠
- `paymentkit.demo.yearly`：年度自动续期订阅，与月度商品同组；首个 1 年以
  `¥148` 预付，之后按 `¥198/年` 续订；包含首年 `¥68` 的优惠代码配置
- `paymentkit.demo.yearly` 在 iOS/macOS 26.4+ 还包含本地月付 12 个月承诺计划；
  价格为 `¥18/月 × 12`、总承诺 `¥216`

本地配置使用中国大陆 storefront，并与当前 Sandbox 的四个商品、订阅层级、参考名称、
本地化、价格及有效优惠保持一致；Sandbox 尚未创建的非续期订阅和回归优惠不会仅为
本地测试额外加入。示例可选择定价方案和首购/促销优惠，展示实际交易优惠、承诺进度、
PurchaseIntent 与 StoreKit 系统消息。促销 compact JWS 调试输入只保存在当前进程
内存中；所有展示价格都来自 StoreKit 的 `displayPrice`，不硬编码货币符号或汇率。

StoreKit 本地测试在本机运行，不连接 App Store 服务器。`Examples` Scheme 加载本地
配置并绑定 `Examples Local` test plan；该计划运行确定性的 StoreKitTest 与共享模拟
后台测试，并明确排除 `SandboxStoreKitProbeTests`。`Examples Sandbox` Scheme 不加载
`.storekit`，绑定 `Examples Sandbox` test plan，只运行 App Store Connect 商品探针和
Sandbox UI 场景。本地测试不会再因网络、账户或 App Store Connect 状态被污染。
示例模拟后台可注入离线、超时、4xx、5xx、成功后断连。

### Sandbox 一次性优惠代码

`Examples/LocalConfiguration/SandboxOfferCodes.csv` 保存 App Store Connect Sandbox
一次性优惠代码。该文件没有被 Git 忽略；更新代码批次时，从 App Store Connect
下载新文件并完整替换：

```text
Examples/LocalConfiguration/SandboxOfferCodes.csv
```

构建配置只把该文件复制到示例主 App Bundle，不复制到 `PaymentKitOutboxProbe`
Share Extension。此安排只用于受控 Sandbox 验收；真实生产 App 禁止打包任何可兑换
代码。

在年订阅的“购买优惠”菜单选择一条代码后，示例会自动切换到预付方案。点击“复制并
兑换优惠代码”，再到 Apple 系统页粘贴代码。iOS 16+ 会等待系统页关闭，并且只在
剪贴板 `changeCount` 仍与写入时一致时清理代码，避免删除用户后来复制的新内容。
iOS 15 的 StoreKit 1 展示接口没有关闭回调，因此使用 `localOnly` 剪贴板并设置
5 分钟 `expirationDate`，调用返回后状态显示“Sandbox 优惠代码兑换页已打开”，
不会假称兑换已经完成。

优惠代码兑换属于外部交易，不能生成或调用普通购买参数。无论系统页何时完成兑换，
交易都依赖 `Transaction.updates` 监听、自动状态刷新、SQLite outbox 和幂等后台处理
完成交付与补 `finish`。

`Examples Sandbox` test plan 显式选择购买、恢复和订阅管理三条自动收敛 UI 用例。
这些用例必须在真机上由测试人员完成 Apple 系统财务界面，不能作为无人值守测试：

- 运行恢复与订阅管理用例的专用 Sandbox 账号在矩阵开始前必须同时满足两项历史
  前置：已经购买 `paymentkit.demo.lifetime`，并且
  `paymentkit.demo.monthly` 当前有效且仍在自动续订。
- 购买用例要求在系统购买页确认一笔 Sandbox 消耗型订单，返回后只等待自动交付和
  `finish` 结果，不点击诊断刷新。
- 恢复用例使用事先购买过 `paymentkit.demo.lifetime` 的专用账号。测试先把该既有
  权益作为账号前置条件，再执行用户主动恢复；返回后仍通过
  `entitlement-paymentkit.demo.lifetime` 验证同一权益，并通过
  `pending-transactions-count` 等待 `待处理交易（0）`。这证明恢复快照与可靠交付
  积压已收敛，不表示恢复操作从无到有新授予了永久权益。
- 订阅管理用例只观察
  `auto-renew-status-paymentkit.demo.monthly`：同一元素在系统页打开前必须严格为
  “将自动续订”，测试人员关闭月订阅自动续订并返回后必须严格变为“不会自动续订”。
  年订阅或另一条订阅的相同文案不能让测试通过。

XCTest 不点击、填写或伪造 Apple 系统购买、认证和订阅管理界面，只检测系统界面
往返并验证 App 返回后的状态。运行这些用例前必须准备相互匹配的 Sandbox 账号历史。

2026-07-27 已在真实 iPhone Sandbox 完成一组不点击诊断刷新的自动刷新验收：月订阅
购买后自动交付并 `finish`，从系统订阅管理页关闭自动续订后返回即自动显示“不会
自动续订”，Sandbox 自然到期后自动显示“已过期”，且 pending 始终为 0。共享模拟
后台计数在购买时由 `13/10` 恰好增加为 `14/11`，到期和再次重启后仍保持
`14/11`，证明状态刷新与补 `finish` 没有重复业务交付。

同日真机恢复测试还发现：`AppStore.sync()` 认证系统页产生的应用激活通知可能在
认证结束前触发自动刷新，并把 StoreKit 的瞬时空权益提交到界面。框架现会在显式
同步在途期间仅抑制这种 `application-active` 刷新；同步成功后仍由恢复流程主动
完整刷新，失败或取消则保留最近有效快照。修复后恢复成功，权益保持 2 项、pending
保持 0；共享签名事件由 `14` 增至 `15`，业务交付仍为 `11`，证明重新签名没有
重复业务交付。

2026-07-30 在真实 iPhone SE Sandbox 复测预付年订阅关闭自动续订。Apple 系统页
已显示“已取消订阅”，但订阅组查询、状态序列和按交易查询一度同时返回外层
`willAutoRenew == true`；换网、等待和冷启动均未改变，说明当前设备仍收到陈旧但
签名有效的 renewal 快照，而不是 App 错读了月付承诺的内层字段。用户明确执行
“恢复购买”触发 `AppStore.sync()` 后，首次启动和强制退出后的冷启动均稳定显示
“不会自动续订”，预付权益仍有效且 pending 为 0。自动路径仍不会静默同步；生产
环境应以 Server Notifications V2 和 Get All Subscription Statuses 为最终权威。
完整证据和处理流程见
[`willAutoRenew` 专题文档](docs/will-auto-renew-troubleshooting.md)。

2026-07-28 又在同一真实 iPhone Sandbox 完成年订阅一次性优惠代码矩阵。Apple
系统页确认首年 `¥68`、之后 `¥198/年`；返回 App 后没有点击诊断刷新，在 10 秒
观察窗口内自动出现年订阅权益，实际优惠映射为“优惠代码 · 预付优惠 · 1 年”，
订阅有效且 pending 为 0。共享签名事件/业务交付由 `15/11` 恰好增加为 `16/12`，
脱敏 transaction suffix 为 `103883`。强制结束并重启后权益和优惠元数据仍存在，
pending 仍为 0，计数仍为 `16/12`，证明外部优惠代码交易只完成一次业务交付。
第一次通过开发工具强制拉起时出现黑屏；随后 4 次独立强制启动均在 3 秒内正常渲染，
其中 3 次已自动截图留证。设备系统崩溃日志中没有 `Examples` 或 `PaymentKit`
记录，应用进程保持运行。该现象暂未复现且没有可证实的代码根因，继续作为受监控的
启动稳定性风险；不能用兑换链路通过替代启动稳定性结论，也不在缺少根因时推测修复。

同一轮真机测试还覆盖了优惠代码负向路径。再次兑换已使用的一次性代码时，Apple
Sandbox 明确拒绝；关闭系统页后签名事件/业务交付保持 `16/12`，pending 为 0。
选择另一条未使用代码并在系统页直接取消，也没有产生购买意图或交易，该代码未被
消耗。只读复制的 outbox 与模拟后台 SQLite 副本均 `quick_check=ok`，outbox 为 0，
共享计数仍为 `16/12`。因此，重复代码和取消兑换都不会形成重复业务交付或遗留记录。

同一设备还验证了已持有非消耗品的再次购买。StoreKit 没有重复显示确认页，而是返回
原永久解锁交易 `…599114`。该交易早于共享 SQLite 模拟后台，因此第一次返回时，新
账本将它记录为首次业务交付，计数由 `16/12` 变为 `17/13`；这属于开发账本未迁移旧
记录的边界，不是新交易。账本已有记录后再次执行相同操作，签名事件/业务交付严格
保持 `17/13`，outbox 为 0，两个数据库均 `quick_check=ok`。生产后台升级时必须保留
历史幂等记录；不能把清空模拟账本后的首次接收误称为重复交付。

普通购买取消也在同一真机环境重新验证：用户在 `paymentkit.demo.coins100` 的 Apple
确认页取消后，应用自动退出 loading，状态映射为“用户取消了购买”而不是错误；
签名事件/业务交付保持 `17/13`，outbox 为 0，两个 SQLite 副本
`quick_check=ok`。取消操作不会生成交易、pending 或业务交付。

主 App 和 `PaymentKitOutboxProbe` Share Extension 都委托 App Group 内同一个模拟后台账本：`Library/Application Support/PaymentKitMockBackend/mock-backend.sqlite3`。账本使用系统 SQLite3、`journal_mode=DELETE`、`synchronous=EXTRA`、`busy_timeout=5000`、`application_id=0x504B4D42` 和 `user_version=1`。`business_deliveries` 以稳定业务状态摘要为主键，`signed_events` 以签名事件摘要为主键；同一业务状态重新签名只增加审计事件，撤销、升级、到期或所有权变化会产生新的业务交付。每次打开都会先只读验证数据库身份、版本和完整性，再应用持久化 PRAGMA，并严格核对固定 DDL、约束、索引、外键，以及业务交付与首个签名事件的双向摘要/结果关联。数据库只保存摘要、结果和时间，不保存 JWS、账户令牌、完整交易 ID 或业务权益；损坏、错误 header、被篡改 schema、错误事件关联和未来版本都会失败关闭，不会静默清空幂等记录或改变未知数据库的日志模式。

主应用和扩展同时使用 `group.com.paymentkit.examples` 与命名空间 `com.paymentkit.examples.payment-outbox` 访问 PaymentKit outbox。扩展从系统分享面板打开，显示共享 outbox 的处理前/后数量、本次“首次交付/幂等命中”以及共享签名事件/业务交付计数；它不会显示敏感字段，也不会授予业务权益。

人工验证建议：

1. 运行 `Examples` 共享 Scheme，确认四个 Sandbox 商品均能加载。
2. 依次购买四个商品，观察后台记录先成功，交易随后 finish。
3. 选择“离线”后购买，确认界面显示“等待后台交付”；不点击刷新、不点击重试且不
   重启应用，直接把故障模式切回“正常”，确认 outbox 自动重放并清零。StoreKit 能
   恢复原始交易时会 finish；本地工具若漏报原始句柄，则显示“已交付，等待 finish”。
4. 选择“成功后断连”并在错误出现后强制结束应用；重启后确认框架自动重放，模拟后台
   显示“幂等命中”，不会产生第二次后台交付。
5. 使用“恢复购买”“申请退款”，并在 iOS 上验证“管理订阅”。
6. 在 Xcode 的 **Debug > StoreKit > Manage Transactions** 中测试 Ask to Buy、续订、到期、billing retry、grace period 和撤销。

Share Extension 真机验证：

1. 卸载旧示例，重新安装包含扩展的构建，确保没有遗留 JSON 开发数据。
2. 主应用将“故障注入”设为“离线”，完成一笔 Sandbox 消耗型购买，确认“待处理交易”显示“等待后台交付”。
3. 强制结束主应用，从任意文本或网页的系统分享面板打开 **PaymentKit Outbox**。
4. 确认扩展显示“处理前：1 笔”，点击“重试共享 outbox”。StoreKit 可能产生两种合法结果：
   - 扩展取得原始交易句柄：`尝试 1 · 交付 1 · finish 1 · 等待 finish 0 · 失败 0`，处理后 0 笔。
   - 扩展暂时没有原始交易句柄：`尝试 1 · 交付 1 · finish 0 · 等待 finish 1 · 失败 0`，处理后仍为 1 笔并保持 `deliveredAwaitingFinish`。
5. Debug 构建可打开“后台提交后暂停 15 秒”，再点击重试；共享后台提交后、客户端
   尚未标记 delivered 或调用 `finish()` 时强制结束扩展。再次打开且关闭停顿后重试，
   确认显示“幂等命中”，共享业务交付计数不增加。该开关不会进入 Release 行为。
6. 再形成一笔失败订单。Debug 构建在主应用点击“准备主 App/扩展并发重试”，并在
   25 秒内从扩展打开“后台提交后暂停 15 秒”后重试。主应用会在扩展提交后台期间
   并发重放同一 outbox；共享签名事件可以被两个进程观察，但同一业务摘要的交付
   计数只能增加一次。这两个确定性测试入口均不会进入 Release 构建。
7. 重启主应用。扩展已 finish 时应保持 0 笔；扩展只完成后台交付时，主应用取得原始句柄后只补 `finish()` 并清零。若 StoreKit 仍未返回句柄，记录会安全保留。
8. 重启后确认共享后台业务交付计数不变。分别检查 outbox 与模拟后台 SQLite：`quick_check=ok`、`journal_mode=delete`、使用中的连接 `synchronous=3`、`user_version=1`、数据库权限 `0600`，并扫描确认没有 JWS、`appAccountToken` 或完整交易 ID。

早期真机结果发生在共享 SQLite 模拟后台引入前，只能证明 App Group outbox、跨进程
锁与 finish 补偿链路。2026-07-28 已在当前共享后台架构上重新完成核心矩阵：主 App
离线购买消耗品交易 `…146643` 后，outbox 恰好保留 1 条 `awaitingDelivery`；
SIGKILL 主 App 后，真实 Share Extension 显示处理前 1 笔，并报告
`尝试 1 · 交付 1 · finish 1 · 等待 finish 0 · 失败 0`、
`本次首次交付 1 · 幂等命中 0`，处理后 0 笔。共享计数最终为 `19/15`。主 App
重启后 3 秒内正常渲染，pending 保持 0，计数保持 `19/15`；两个数据库
`quick_check=ok`、`journal_mode=delete`。测试期间同时发生的年订阅事件
`…144979` 已通过本进程记录与失败消耗品区分，不属于提前交付。

上述结果完成了步骤 1～4、7 以及步骤 8 的完整性与日志模式检查。使用中的连接
`synchronous=3`、文件权限与脱敏仍由自动测试和最终设备检查继续验证。

随后用 Debug 专用的“后台提交后暂停 15 秒”完成步骤 5 的确定性真机验收。基线 outbox
为 1 条 `awaitingDelivery`，共享签名事件/业务交付为 `23/18`。扩展开始重试后，共享
后台先原子提交为 `24/19`；监控检测到提交后立即向扩展 PID 发送 `SIGKILL`。扩展进程
消失时，outbox 仍有同一 transaction ID 的两份不同签名记录，均为
`awaitingDelivery`，证明后台成功并未导致客户端提前标记或 `finish()`。重新打开扩展、
关闭停顿并重试后，后台命中同一签名事件的幂等记录，outbox 清零且共享计数严格保持
`24/19`。主 App 重启后 outbox 仍为 0、计数仍为 `24/19`；每个阶段复制的两份 SQLite
均 `quick_check=ok`、`journal_mode=delete`。

最后使用 Debug 专用的主应用后台探针完成了步骤 6 的严格并发真机验收。测试前
outbox 为 1 条 `awaitingDelivery`，共享签名事件/业务交付为 `25/20`。扩展在后台提交
后暂停 15 秒期间，设备进程列表同时存在主应用 PID `4254` 与扩展 PID `4259`；主应用
取得后台执行时间并重放同一 outbox。窗口内共享账本形成同一业务摘要的一条首次交付
和一条重新签名幂等事件，计数为 `27/21`，outbox 清零。暂停结束后两个进程仍存活，
计数和 outbox 均未变化；两份数据库均 `quick_check=ok`、`journal_mode=delete`、
`application_id` 与 `user_version=1` 正确。随后主应用重启时另收到一笔
`paymentkit.demo.yearly` Sandbox 自动续订交易 `…258553`，因此总计数合法增加为
`28/22`；应用本进程记录和 `PaymentEvent` 均确认它不是本次
`paymentkit.demo.coins100` 并发订单。重启后 outbox 仍为 0。由此步骤 6 已通过：
两个真实进程竞争同一订单时只产生一次业务交付，重新签名仅增加审计事件。

同轮分别编译了 Debug 真机包和未签名 Release iOS 包。Release 二进制扫描确认
“后台提交后暂停 15 秒”“准备主 App/扩展并发重试”和后台任务探针标识均不存在，
故这些故障注入入口不会扩大生产发布面的行为。

同轮原始文件扫描还发现：未启用 `secure_delete` 的旧调试构建即使 outbox 已清零，
SQLite 空闲页仍可能保留已删除的交易 JWS。当前实现已对每个 outbox 短连接强制启用
并验证 `secure_delete=ON`，并增加“写入唯一秘密标记 → 删除交易 → 扫描数据库字节”
回归测试。干净重装修复后的真机包后，完成一笔真实 Sandbox 消耗品购买；outbox
收敛为 0，共享模拟后台严格为 1 个签名事件/1 次业务交付。两份 SQLite 均
`quick_check=ok`、`journal_mode=delete`、`user_version=1`、权限 `0600`，原始文件
扫描均未发现 JWS compact 前缀、`appAccountToken` 或 `jwsRepresentation`。

同日还单独验证了“后台已成功、响应在返回客户端前断开”的崩溃窗口。基线共享计数
为 `19/15`；消耗品交易到达模拟后台后，计数变为 `20/16`，但客户端收到可靠交付
失败，outbox 保留 1 条 `awaitingDelivery`。在失败提示仍显示时 SIGKILL 主 App，
随后重新启动；框架自动重放并完成 `finish()`，outbox 清零。重新签名使审计事件
增加为 21，其中首次交付 16、幂等命中 5，但业务交付始终保持 16。两份数据库均
`quick_check=ok`，应用在 3 秒观察窗口内正常渲染。该结果证明当前实现覆盖
“后台提交成功、客户端未获成功响应、应用又在落盘已交付状态前终止”的至少一次
交付窗口：重启允许重复请求，但不会重复业务交付。

同日完成了后台恢复自动触发的独立真机验收。测试前 outbox 为 0，共享签名事件/业务
交付为 `22/17`；将模拟后台设为离线并完成一笔 Sandbox 消耗品购买后，只把故障模式
切回“正常”，全程没有点击刷新或重试，也没有切换前后台或重启应用。PaymentClient
自动重放并完成 `finish()`，outbox 回到 0，签名事件/业务交付严格增加为 `23/18`。
模拟后台累计结果为首次交付 18、幂等命中 5；两份 SQLite 副本均
`quick_check=ok`、`journal_mode=delete`。这证明后台恢复信号可以驱动可靠链路自动
收敛，同时不会绕过 outbox 或产生重复业务交付。

自动验证：

```sh
swift test
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan 'Examples Local' \
  -destination 'platform=macOS,arch=arm64' \
  test
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan 'Examples Local' \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=17.0' \
  -only-testing:'ExamplesTests/PaymentKitStoreKitTests/mapsSimulatedLoadProductsError()' \
  test
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme 'Examples Sandbox' \
  -destination 'id=00008030-001E69322223802E' \
  build
```

StoreKitTest 用例串行清理测试会话。当前 Xcode 26.x 通过 `xcodebuild test` 运行时，可能遇到[本地配置没有注入 `storekitd` 的工具链问题](https://developer.apple.com/forums/thread/808030)；商品为空会直接使集成测试失败，不再作为 Known Issue 形成假绿。fake gateway 单测不能替代 StoreKitTest 有效执行。

本仓库先前验证时，iOS 16 Simulator 的商品加载、商品购买、Ask to Buy
批准和 unfinished 重放共 4 项通过；自动续订到期用例未通过，因为
`SKTestSession` 没有把 `expireSubscription` 或
`disableAutoRenewForTransaction` 的状态传播给 StoreKit。该断言仍保持失败，不能把
fake gateway 覆盖或版本条件当成集成测试通过。系统错误注入 API 仅存在于 iOS 17+/
macOS 14+；iOS 17 的对应真实用例当前为 1 项通过、0 失败、0 跳过。Xcode 26.5.2
偶尔会在全部 StoreKitTest 合并到单次 `xcodebuild test` 后卡在
`Blocking finish to clean up test session`，此时测试子进程已经退出但 xcresult 尚未
完成；分组运行可以稳定退出并保留有效结果。iOS 26.5 Simulator 当前还没有返回本地
配置中的 `winBackOffers`，并拒绝本地月付承诺购买（`.notEntitled`）。这些工具链异常
都会保留为明确的环境阻塞，不会转换成通过结果。

当前本地配置已按中国大陆 Sandbox 保存月付承诺价格，源文件明确包含
`¥18/月` 与 `¥216/12 个月`。但 macOS 26.5.2 的 StoreKitTest 运行时仍可能返回
错误的 `commitmentInfo.price`，并在
`SKTestSession.buyProduct(options: [.billingPlanType(.monthly)])` 时忽略该选项：
返回交易的 `billingPlanType` 与 `commitmentInfo` 均为 `nil`。Local test plan 保留
两项强失败断言，未用“月价 × 12”、skip 或放宽期望伪造通过；在 Apple 修复工具链
或提供可正确返回承诺交易的运行环境前，此项保持“环境阻塞”。

自动刷新单元测试和示例接线测试不替代上述 StoreKitTest 承诺计划断言。只要当前
Xcode 26.6 / macOS 26.5.2 运行时仍返回错误总价或丢失交易承诺字段，完整 Local test
plan 就必须保持失败，不能把这项工具链阻塞写成通过。

## 开发专用优惠签名工具

`paymentkit-offer-signer` 是仅在 macOS 运行的开发/Sandbox 工具。它使用 CryptoKit
ES256，按 Apple 的 JWS 声明格式签发首购资格或促销优惠，并把导入的 P-256 `.p8`
私钥存入本机 Keychain；Keychain 条目不可同步且仅当前设备可用。

先从 App Store Connect 创建 In-App Purchase Key，并在用户确认后把下载的私钥导入：

```sh
swift run paymentkit-offer-signer import-key \
  --alias paymentkit-sandbox \
  --p8 /private/path/SubscriptionKey_ABC123.p8
```

签发首购资格：

```sh
swift run paymentkit-offer-signer sign-intro \
  --alias paymentkit-sandbox \
  --key-id ABC123 \
  --issuer-id 00000000-0000-0000-0000-000000000000 \
  --bundle-id com.example.app \
  --product-id com.example.subscription.monthly \
  --transaction-id 1234567890 \
  --allow true
```

签发促销优惠：

```sh
swift run paymentkit-offer-signer sign-promo \
  --alias paymentkit-sandbox \
  --key-id ABC123 \
  --issuer-id 00000000-0000-0000-0000-000000000000 \
  --bundle-id com.example.app \
  --product-id com.example.subscription.monthly \
  --offer-id retention_offer \
  --transaction-id 1234567890
```

签名命令只向标准输出返回一次 compact JWS；错误信息不回显私钥、JWS 或账户令牌。
除下述经用户明确授权的 Sandbox CSV 例外外，不要把 `.p8`、JWS、命令历史、生产
优惠代码、其他优惠代码批次或凭据提交到仓库。这个工具不能替代生产后台；正式环境
必须在受控服务中保存密钥、鉴权、判断业务资格、限时签名并记录审计。

## Sandbox 真机边界

Sandbox 使用 App Store Connect 的真实商品和 Apple 签名交易，但不会产生费用。独立测试应用固定使用 `com.paymentkit.examples`，不得复用或修改其他生产应用。开发签名、设备注册、Sandbox Apple Account 密码，以及付费协议、银行、税务和地区合规信息必须由有权限的人员在 Apple 页面确认；仓库不会保存这些凭据。

当前独立环境已创建 App Store Connect 应用 `PaymentKit Sandbox MP8Z`（Apple ID `6793464482`）和订阅组 `PaymentKit Demo Subscription`（群组 ID `22255725`）。四个商品 ID 均已建立基础记录，真实 iPhone 已完成商品加载、购买和跨进程 outbox 验收。月订阅已经配置中国大陆和美国首周免费；年订阅标准价为美国 `$29.99`（中国大陆 `¥198`），并配置首年预付美国 `$19.99`（中国大陆 `¥148`）。两项首购优惠均从 2026 年 7 月 24 日开始且无结束日期。仍需使用两个没有同组购买历史的 Sandbox 账户分别完成月、年首购真机矩阵；同一个账户不能重复验证同一订阅组资格。提交 App Review 或公开发布前，付费应用程序协议、银行、税务、完整本地化元数据及地区合规资料仍必须由有权限的账户持有人最终确认。

截至 2026 年 7 月 30 日，App Store Connect 中已保存并由中国区真实 iPhone
Sandbox 读取到以下配置：

- 月订阅标准价为美国 `$2.99/月`、中国大陆 `¥22/月`，包含 7 天免费试用，以及促销 ID
  `pk_monthly_promo_099_2m_2026` 的美国 `$0.99/月 × 2`、中国大陆 `¥8/月 × 2`
  按期优惠。
- 年订阅标准价为美国 `$29.99/年`、中国大陆 `¥198/年`；首年预付优惠为美国
  `$19.99`、中国大陆 `¥148`。
- 年订阅优惠代码活动 `pk_annual_code_999_2026` 已创建 10 个 Sandbox 代码，
  首年价格为美国 `$9.99`、中国大陆 `¥68`，覆盖新、现有和过期用户。App Store
  Connect 当时允许的最晚到期日为 2027 年 1 月 23 日。本仓库经用户明确授权，将
  `Examples/LocalConfiguration/SandboxOfferCodes.csv` 作为版本化例外，只供独立
  Sandbox 示例使用且只进入示例主 App Bundle；不得将生产优惠代码打入生产 App，
  也不得把该例外扩展到其他批次、凭据、JWS 或私钥。实际代码不得写入日志。
- 中国大陆月付承诺方案为 `¥18/月 × 12`，总承诺金额 `¥216`。App Store Connect
  要求月付总额不得低于同区年付价格，因此原计划 `¥15/月 × 12` 无法保存。该方案
  未向美国开放。

真实 iPhone（iOS 26.5.2）的原生 StoreKit 探针返回
`BILLED_UPFRONT: ¥198 / ¥198` 与 `MONTHLY: ¥18 / ¥216`；界面自动化也已选择
月付方案并验证“总承诺”金额和期限。月订阅促销优惠及首购资格状态同轮通过真实
Sandbox 界面验证。上述测试只读取商品并选择展示方案，没有确认新的订阅购买。

回归优惠仍受 Apple 后台前置条件阻塞：App Store Connect 要求订阅先通过
App Review，当前测试应用按本项目约束不提交审核，因此无法创建真实回归优惠。
框架 API 和 fake gateway 仍覆盖回归优惠能力；本地 `.storekit` 为保持与 Sandbox
一致，不包含 `pk_monthly_winback_free1m_2026`，不得把它标记为真实 Sandbox
端到端通过。
Sandbox 代码、In-App Purchase 私钥和签名 JWS 不写入本文档、源码、日志或模拟
后台数据库。

截至 2026 年 8 月 3 日，iPhone SE（iOS 26.6）真机矩阵已经覆盖干净重装、离线与
弱网恢复、Sandbox 账户切换、家庭共享增删、双设备续订状态传播、账单失败恢复，
以及预付年订阅退款撤销和撤销后的冷启动。退款撤销在 Apple 接受申请约 15 分钟后
到达，框架只交付一次新的撤销业务状态并保持 pending 为 0。Billing Grace Period
仍是明确的外部阻塞项：App Store Connect 保存为 `3 days / all renewals / Sandbox
only` 后，九个独立的 3 分钟续订周期都从“有效”直接进入“账单重试”，没有下发
“宽限期”。因此不得把真机宽限期标记为通过或 PaymentKit 失败；确定性的
StoreKitTest 仍覆盖宽限期映射和到期边界。完整逐项证据和 PASS/FAIL/BLOCKED
分类见
[`2026-07-30-abnormal-subscription-lifecycle-real-device-qa.md`](docs/superpowers/plans/2026-07-30-abnormal-subscription-lifecycle-real-device-qa.md)。

## 生产后台

仓库不包含真实 HTTP 后台、App Store Server Notifications 服务或业务数据库。生产环境仍需独立接入 [App Store Server API](https://developer.apple.com/documentation/appstoreserverapi) 与 [App Store Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications)，并维护跨设备、跨启动的幂等交付记录。

PaymentKit 已提供首购资格 JWS、促销授权 JWS、回归购买、优惠代码系统入口、
PurchaseIntent 和实际优惠快照，但不会决定用户能否获得业务权益，也不会在客户端
生成生产签名。StoreKit 1 仅在 iOS 15 用于展示 Apple 没有提供 StoreKit 2 替代项
的优惠代码兑换页；商品、购买、交易验证和可靠交付全部使用 StoreKit 2。
