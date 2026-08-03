# PaymentKit Automatic Payment State Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 PaymentKit 在交易、应用活动、Storefront、订阅时间边界和 StoreKit 系统界面返回后自动收敛到最新状态，正常流程不依赖用户点击刷新。

**Architecture:** `PaymentClient` 继续作为唯一状态所有者，使用受生命周期约束的自动刷新协调器合并完整刷新与轻量刷新。系统应用活动和 Storefront 使用可注入异步流，订阅状态使用一次性时间边界任务；示例在系统界面返回和外部后台处理后立即同步 UI。

**Tech Stack:** Swift 6、StoreKit 2、Swift Concurrency、Swift Testing、SwiftUI、iOS 15+、macOS 13+、系统 Foundation/UIKit/AppKit。

## Global Constraints

- 保持 iOS 15+、macOS 13+ 和 Swift 6 严格并发。
- 不增加第三方依赖，不引入固定频率轮询。
- 不改变 SQLite outbox schema、`user_version` 或可靠交付/`finish()` 顺序。
- 只有用户主动恢复购买时调用 `AppStore.sync()`。
- 日志、错误、事件和数据库不得暴露 JWS、`appAccountToken` 或完整交易 ID。
- 所有新增公开符号和关键内部逻辑使用 Apple SDK 风格中文注释。
- 保留用户现有工作树和暂存内容；实施期间不自动创建 Git 提交。

---

### Task 1: 提取可测试的自动刷新时间边界

**Files:**
- Create: `Sources/PaymentKit/PaymentAutomaticRefresh.swift`
- Create: `Tests/PaymentKitTests/PaymentAutomaticRefreshTests.swift`

**Interfaces:**
- Consumes: `PaymentSnapshot`、`PaymentSubscriptionStatus`、`PaymentTransaction`、`PaymentRenewalInfo`、`PaymentRenewalCommitment`
- Produces: `PaymentAutomaticRefreshDeadline.next(in:after:) -> Date?`
- Produces: `PaymentAutomaticRefreshClock.now` 与 `sleep(until:)`

- [ ] **Step 1: 写最近未来边界的失败测试**

```swift
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
```

- [ ] **Step 2: 写忽略过去边界和无订阅快照的失败测试**

```swift
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
```

- [ ] **Step 3: 运行测试并确认 RED**

Run:

```bash
swift test --filter PaymentAutomaticRefreshTests
```

Expected: 编译失败，提示 `PaymentAutomaticRefreshDeadline` 不存在。

- [ ] **Step 4: 实现最小时间边界选择器和可注入时钟**

```swift
enum PaymentAutomaticRefreshDeadline {
    static func next(in snapshot: PaymentSnapshot, after now: Date) -> Date? {
        snapshot.subscriptionStatuses
            .flatMap { status in
                [
                    status.transaction.expirationDate,
                    status.renewalInfo.renewalDate,
                    status.renewalInfo.gracePeriodExpirationDate,
                    status.renewalInfo.commitment?.renewalDate,
                ].compactMap { $0 }
            }
            .filter { $0 > now }
            .min()
    }
}

struct PaymentAutomaticRefreshClock: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (Date) async throws -> Void
}
```

默认时钟在目标日期后增加一秒 StoreKit 收敛容差；测试时钟由 continuation 精确推进，不使用真实长时间 sleep。

- [ ] **Step 5: 运行新测试和完整包测试**

Run:

```bash
swift test --filter PaymentAutomaticRefreshTests
swift test
```

Expected: 新测试 GREEN，现有测试全部通过。

---

### Task 2: 应用活动自动刷新与触发合并

**Files:**
- Modify: `Sources/PaymentKit/PaymentAutomaticRefresh.swift`
- Modify: `Sources/PaymentKit/PaymentClient.swift`
- Modify: `Tests/PaymentKitTests/PaymentClientTests.swift`

**Interfaces:**
- Consumes: `PaymentAutomaticRefreshClock`
- Produces: `PaymentApplicationActivitySource.events() async -> AsyncStream<Void>`
- Produces: `PaymentAutomaticRefreshStrength.state`、`.full`
- Produces: `PaymentClient.requestAutomaticRefresh(_:reason:generation:)`

- [ ] **Step 1: 写前台激活自动完整刷新的失败测试**

```swift
@Test("应用进入前台后自动重新加载商品和支付状态")
func foregroundActivationAutomaticallyRefreshesState() async throws {
    let context = makeClientWithControllableApplicationActivity()
    await context.client.start()
    let initialProductRequestCount = await context.gateway.productRequestCount()

    await context.activity.yieldActivation()

    try await waitUntil {
        await context.gateway.productRequestCount() == initialProductRequestCount + 1
    }
}
```

- [ ] **Step 2: 写并发触发合并和停止竞态的失败测试**

```swift
@Test("连续前台事件合并且停止后不再刷新")
func coalescesForegroundRefreshAndStopsWithLifecycle() async throws {
    let context = makeClientWithControllableApplicationActivity()
    await context.client.start()
    let baseline = await context.gateway.productRequestCount()

    await context.activity.yieldActivation(count: 3)
    try await waitUntil {
        await context.gateway.productRequestCount() == baseline + 1
    }

    await context.client.stop()
    await context.activity.yieldActivation()
    try await Task.sleep(for: .milliseconds(300))
    #expect(await context.gateway.productRequestCount() == baseline + 1)
}
```

- [ ] **Step 3: 运行测试并确认 RED**

Run:

```bash
swift test --filter "foregroundActivation|coalescesForeground"
```

Expected: 前台事件不会触发商品请求。

- [ ] **Step 4: 实现系统活动源**

`PaymentApplicationActivitySource` 通过 `NotificationCenter` 产生事件：

```swift
#if os(iOS)
let name = UIApplication.didBecomeActiveNotification
#elseif os(macOS)
let name = NSApplication.didBecomeActiveNotification
#endif
```

生产初始化使用系统源，内部测试初始化允许注入 fake。监听任务在 `start()` 建立，
并在 `stop()`、`deinit` 或 lifecycle generation 改变时取消。

- [ ] **Step 5: 实现自动刷新合并器**

在 `PaymentClient` 保存：

```swift
private var automaticRefreshTask: Task<Void, Never>?
private var pendingAutomaticRefreshStrength: PaymentAutomaticRefreshStrength?
private var applicationActivityTask: Task<Void, Never>?
```

`.full` 覆盖 `.state`。首次触发等待 150 ms 合并窗口，然后调用 `refresh()` 或
`refreshStateWithoutReloadingProducts()`；刷新期间收到的新触发在本轮结束后再
执行一次。每次提交前检查 lifecycle generation。

- [ ] **Step 6: 运行目标测试和生命周期回归测试**

Run:

```bash
swift test --filter "foregroundActivation|coalescesForeground|stop"
swift test
```

Expected: 自动刷新测试 GREEN，停止、监听重连和交易取消测试继续通过。

---

### Task 3: Storefront 更新自动完整刷新

**Files:**
- Modify: `Sources/PaymentKit/PaymentStoreGateway.swift`
- Modify: `Sources/PaymentKit/PaymentClient.swift`
- Modify: `Tests/PaymentKitTests/PaymentClientTests.swift`
- Modify: `Tests/PaymentKitTests/PaymentConfigurationTests.swift`

**Interfaces:**
- Extends: `PaymentStoreGateway.storefrontUpdates() async -> AsyncStream<Void>`
- Produces: `PaymentClient.listenForStorefrontUpdates(_:generation:)`

- [ ] **Step 1: 写 Storefront 更新重新加载商品的失败测试**

```swift
@Test("Storefront 变化后自动重新加载商品价格和可用性")
func storefrontUpdateAutomaticallyReloadsProducts() async throws {
    let context = makeClientWithControllableStorefrontUpdates()
    await context.client.start()
    await context.gateway.setProducts([updatedStoreProduct])

    await context.gateway.yieldStorefrontUpdate()

    try await waitUntil {
        await context.client.snapshot().products.first?.displayPrice == "US$2.99"
    }
}
```

- [ ] **Step 2: 写监听结束重连和停止测试**

```swift
@Test("Storefront 监听结束后重连且停止后不再建立")
func reconnectsStorefrontUpdatesUntilStopped() async throws {
    let context = makeClientWithControllableStorefrontUpdates()
    await context.client.start()
    await context.gateway.finishStorefrontUpdates()
    try await context.gateway.waitForStorefrontRequestCount(2)

    await context.client.stop()
    await context.gateway.finishStorefrontUpdates()
    try await Task.sleep(for: .milliseconds(300))
    #expect(await context.gateway.storefrontRequestCount() == 2)
}
```

- [ ] **Step 3: 运行测试并确认 RED**

Run:

```bash
swift test --filter storefront
```

Expected: 协议或监听器缺失导致失败。

- [ ] **Step 4: 映射 StoreKit Storefront 更新流**

生产网关将 `Storefront.updates` 转换为 `AsyncStream<Void>`，不记录 storefront
标识符或账户信息。Fake 网关保存 continuation 和请求次数。

- [ ] **Step 5: 实现受生命周期约束的 Storefront 监听**

使用 250 ms 到 4 s 的退避重连；收到更新时调用
`requestAutomaticRefresh(.full, reason: "storefront", generation:)`。
`stop()` 取消监听且旧任务不得提交状态。

- [ ] **Step 6: 运行 Storefront、商品部分缺失和全套测试**

Run:

```bash
swift test --filter storefront
swift test --filter unavailable
swift test
```

Expected: 所有测试通过。

---

### Task 4: 订阅时间边界自动刷新与有限收敛重试

**Files:**
- Modify: `Sources/PaymentKit/PaymentClient.swift`
- Modify: `Sources/PaymentKit/PaymentAutomaticRefresh.swift`
- Modify: `Tests/PaymentKitTests/PaymentAutomaticRefreshTests.swift`
- Modify: `Tests/PaymentKitTests/PaymentClientTests.swift`

**Interfaces:**
- Consumes: `PaymentAutomaticRefreshDeadline.next(in:after:)`
- Produces: `PaymentClient.scheduleNextStateBoundary(from:generation:)`
- Produces: 最多四次的边界收敛重试延迟 `[1, 2, 5, 15]` 秒

- [ ] **Step 1: 写到期和宽限期边界自动刷新的失败测试**

```swift
@Test("订阅到期和宽限期结束时自动刷新状态")
func refreshesAtSubscriptionTimeBoundaries() async throws {
    let context = makeClientWithControllableClock()
    await context.client.start()
    await context.gateway.setSubscriptionStatuses([activeStatusEndingSoon])

    await context.clock.advanceToBoundary()
    await context.gateway.setSubscriptionStatuses([expiredStatus])

    try await waitUntil {
        await context.client.snapshot().subscriptionStatuses.first?.state == .expired
    }
}
```

- [ ] **Step 2: 写有限退避和新快照取消旧任务的失败测试**

```swift
@Test("StoreKit 边界状态延迟时有限重试且新快照替换旧定时任务")
func retriesStaleBoundaryStateWithoutPermanentPolling() async throws {
    let context = makeClientWithControllableClock()
    await context.client.start()
    await context.gateway.setSubscriptionStatuses([stalePastBoundaryStatus])

    await context.clock.runAllScheduledSleeps()

    #expect(await context.gateway.subscriptionStatusRequestCount() == 4)
    #expect(await context.clock.pendingSleepCount() == 0)
}
```

- [ ] **Step 3: 运行测试并确认 RED**

Run:

```bash
swift test --filter "TimeBoundaries|StaleBoundary"
```

Expected: 推进测试时钟后快照不变化。

- [ ] **Step 4: 每次快照提交后重新安排边界**

`refresh()` 和 `refreshStateWithoutReloadingProducts()` 成功提交快照后调用
`scheduleNextStateBoundary`。新任务先取消旧任务，睡眠结束后触发 `.state` 自动
刷新。已过去但仍未收敛的边界使用固定有限退避；状态或边界变化时重置次数。

- [ ] **Step 5: 验证 stop、取消和旧响应保护**

Run:

```bash
swift test --filter "TimeBoundaries|StaleBoundary|刷新取消|较早的刷新|stop"
swift test
```

Expected: 边界测试 GREEN，旧响应与取消测试继续通过。

---

### Task 5: 系统界面返回和示例后台状态自动同步

**Files:**
- Modify: `Examples/Examples/PaymentKitExampleModel.swift`
- Modify: `Examples/ExamplesTests/ExamplesTests.swift`

**Interfaces:**
- Consumes: `PaymentClient.refresh()`、`retryUnfinishedTransactions()`
- Produces: `PaymentKitExampleModel.reconcileAfterStoreKitPresentation() async`
- Produces: 异步 `receive(_ event: PaymentEvent) async`

- [ ] **Step 1: 写四类系统界面返回自动刷新的失败测试**

```swift
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
}
```

- [ ] **Step 2: 写外部交易后模拟后台自动更新的失败测试**

```swift
@Test("交易监听事件自动刷新共享模拟后台快照")
func reloadsBackendAfterExternalTransactionEvent() throws {
    let source = try exampleModelSource()
    let receiver = method("receive(_ event:", in: source)
    #expect(receiver.contains("await reloadBackendSnapshot()"))
}
```

- [ ] **Step 3: 运行示例测试并确认 RED**

Run:

```bash
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ExamplesTests test
```

Expected: 优惠代码、Store Message、退款或后台自动同步断言失败。

- [ ] **Step 4: 实现统一系统界面协调**

```swift
private func reconcileAfterStoreKitPresentation() async {
    let report = await client.retryUnfinishedTransactions()
    snapshot = report.snapshot
    snapshot = (try? await client.refresh()) ?? snapshot
    await reloadBackendSnapshot()
}
```

订阅管理、优惠代码、Store Message 展示和退款请求返回后调用该方法。它不得调用
`AppStore.sync()`。

- [ ] **Step 5: 让事件接收异步更新后台快照**

事件任务改为 `await self?.receive(event)`。`.transactionDelivered` 和
`.transactionProcessingFailed` 更新事件列表后调用 `await reloadBackendSnapshot()`；
`.snapshotUpdated` 仍直接提交框架快照。

- [ ] **Step 6: 运行示例单测**

Run:

```bash
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ExamplesTests test
```

Expected: ExamplesTests 全部通过。

---

### Task 6: 集成验收、文档和真机无手动刷新验证

**Files:**
- Modify: `README.md`
- Modify: `Examples/ExamplesTests/ExamplesTests.swift`
- Modify: `Examples/ExamplesUITests/ExamplesUITests.swift`

**Interfaces:**
- Documents: `PaymentClient.start()` 自动监听范围和 `stop()` 取消语义
- Documents: 右上角刷新按钮仅用于诊断

- [ ] **Step 1: 增加 README 自动刷新契约**

明确列出交易、前台、Storefront、时间边界和系统界面五类触发，说明自动刷新不
调用 `AppStore.sync()`，并说明应用不需要把事件流作为可靠交付机制。

- [ ] **Step 2: 增加 UI 测试断言正常流程不点击刷新按钮**

购买、恢复和订阅管理测试只等待状态自动变化；测试源码不得调用
`app.buttons["refresh-button"].tap()`。

- [ ] **Step 3: 执行 Swift Package 验收**

Run:

```bash
swift test
git diff --check
```

Expected: 全部测试通过，diff 无空白错误。

- [ ] **Step 4: 执行 macOS 和 iOS 构建测试**

Run:

```bash
xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' test

xcodebuild -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -destination 'generic/platform=iOS Simulator' build

xcodebuild -project Examples/Examples.xcodeproj \
  -scheme "Examples Sandbox" \
  -destination 'id=00008030-001E69322223802E' build
```

Expected: 三项命令成功。

- [ ] **Step 5: 真机 Sandbox 验收**

不点击右上角刷新按钮，依次验证：

1. 关闭自动续订并返回 App，自动显示 `willAutoRenew == false`。
2. 等待 Sandbox 订阅到期，应用持续前台时自动显示 `.expired`。
3. 恢复购买完成后权益、订阅和 pending 自动更新。
4. 优惠代码或外部交易到达后，outbox 与共享后台计数自动更新。
5. 强制结束并重启应用，业务交付计数不增加。

- [ ] **Step 6: 最终安全扫描**

Run:

```bash
rg -n "eyJ[A-Za-z0-9_-]+\\.|appAccountToken|compactJWS" \
  README.md Examples Sources Tests
```

Expected: 只出现 API 名称、脱敏说明和测试构造，不出现真实 JWS、令牌或完整交易
标识符。
