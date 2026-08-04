# PaymentKit 生产级支付状态自动刷新设计

## 目标

PaymentKit 在应用正常运行期间自动收敛到最新的 StoreKit 商品、权益、订阅和
unfinished 状态。用户不需要点击示例右上角的“刷新”按钮；该按钮仅保留为诊断
入口。

自动刷新不能改变可靠交付边界：只有已验证交易可以进入
`TransactionProcessor`，SQLite outbox 的“落盘、交付、标记、finish、清理”
顺序保持不变。

## 状态变化来源

自动刷新覆盖以下来源：

1. 普通购买、PurchaseIntent、Ask to Buy 批准、自动续订、退款撤销、优惠代码
   和其他 `Transaction.updates` 交易。
2. 应用进入前台后发生的账号、Storefront、续订偏好、价格上涨同意和家庭共享
   变化。
3. Storefront 在应用运行期间发生变化。
4. 订阅交易到期、预计续订和账单宽限期结束等时间边界。
5. 订阅管理、优惠代码兑换、退款请求和 Store Message 等系统界面关闭。
6. unfinished/outbox 自动重放以及模拟后台状态改变。

## 架构

### PaymentClient 自动刷新协调器

`PaymentClient` 继续作为唯一状态所有者。新增内部自动刷新协调器，将短时间内
重复到达的触发合并，并区分两种刷新强度：

- 完整刷新：重新加载商品，并查询权益、unfinished、订阅状态和支付能力。
- 轻量刷新：保留当前商品，仅查询权益、unfinished、订阅状态和支付能力。

Storefront 或应用重新进入前台触发完整刷新；交易和时间边界触发轻量刷新。
同一批触发只执行一次查询。刷新期间到达的新触发在当前查询完成后再执行一次，
防止遗漏；旧生命周期或 `stop()` 后的结果不得提交。

现有请求编号规则继续保证旧响应不能覆盖新响应。自动刷新失败只记录脱敏日志，
保留最后一个完整快照，并在下一次触发时重试。

### 应用活动监听

`start()` 建立平台活动通知监听：

- iOS：`UIApplication.didBecomeActiveNotification`
- macOS：`NSApplication.didBecomeActiveNotification`

收到通知后执行完整自动刷新。监听与 `PaymentClient` 的 lifecycle generation
绑定；`stop()` 会取消监听，重复 `start()` 不会建立重复任务。Share Extension
不依赖该通知完成 outbox 重试，因此没有活动通知时仍能正常工作。

### Storefront 更新监听

StoreKit 网关增加内部 Storefront 更新流。生产网关映射 `Storefront.updates`，
fake 网关提供可控流。更新到达时执行完整自动刷新，使价格、币种、商品可用性和
优惠元数据同步更新。监听异常结束时使用与交易监听相同的有限退避重建策略。

### 订阅时间边界

每次成功提交快照后，PaymentClient 从以下字段选择最近的未来时间：

- `PaymentSubscriptionStatus.transaction.expirationDate`
- `PaymentRenewalInfo.renewalDate`
- `PaymentRenewalInfo.gracePeriodExpirationDate`
- `PaymentRenewalCommitment.renewalDate`

客户端在边界后留出很小的 StoreKit 收敛容差，再执行轻量刷新。若 StoreKit
仍返回跨过边界的旧状态，使用有限退避再次查询；重试次数用尽后停止，等待交易、
前台或 Storefront 事件重新触发，禁止形成永久轮询或忙循环。

新的快照会取消旧定时任务并重新计算边界。`stop()` 取消所有边界任务。

### 系统界面返回

示例在系统界面返回后自动协调状态：

- 订阅管理：重放 unfinished，再完整刷新。
- 优惠代码：重放 unfinished，再完整刷新；成功兑换产生的交易仍以
  `Transaction.updates` 为可靠交付来源。
- Store Message：展示后完整刷新续订信息。
- 退款：提交请求后轻量刷新；真正撤销到达时仍由交易监听再次刷新。

这些刷新不会调用 `AppStore.sync()`。只有用户点击“恢复购买”时才允许执行
`AppStore.sync()`。

### 订阅续订状态的签名快照与字段层级

订阅的当前权益与未来续订意愿必须分开：

- 当前权益由已验证交易的到期、撤销、升级和宽限期状态决定；
- 普通预付订阅使用外层 `renewalInfo.willAutoRenew` 判断下一周期是否续订；
- 月付 12 个月承诺计划的外层字段表示下一笔月度账单，内层
  `commitmentInfo.willAutoRenew` 表示承诺结束后是否开始下一轮完整承诺。

当前订阅状态由 `Product.SubscriptionInfo.status(for:)` 在启动和刷新时主动加载；
`Product.SubscriptionInfo.Status.all` 是会在当前快照枚举完成后结束的有限序列，
不得作为长期监听。所有支持系统的长期变化监听统一消费 `Status.updates`。状态事件与
主动订阅组查询按 renewal JWS `signedDate` 合并：较旧查询不得覆盖较新事件，较新
查询淘汰较旧事件缓存；一次空查询不撤销已验签事件缓存。`stop()`、商店会话热重载
和显式恢复购买会清除会话缓存。iOS 18.4+ 再使用按交易 ID 查询交叉校验组查询。

这些机制不能把仍为 `true` 的签名快照推断成 `false`。2026-07-30 真机 Sandbox
观察到系统订阅页已关闭预付年订阅续订，但所有设备 StoreKit 查询面持续返回陈旧
外层值；换网、等待和冷启动均未收敛。用户明确执行恢复购买并完成
`AppStore.sync()` 后，首次启动和冷启动均得到 `false`。因此：

- 自动路径只刷新和合并已验证状态，不静默执行系统账户同步；
- 用户可通过“恢复购买”显式修复设备 StoreKit 账户缓存；
- 生产后台通过 App Store Server Notifications V2 和
  Get All Subscription Statuses 维护最终业务状态；
- App 不根据系统页往返、等待时间、`autoRenewPreference` 或内层承诺字段猜测
  普通订阅已取消。

完整判定矩阵、故障证据、服务器状态机和验收流程见
[`willAutoRenew` 语义、陈旧状态与生产级收敛](../../will-auto-renew-troubleshooting.md)。

### 示例界面同步

示例继续订阅 `PaymentEvent.snapshotUpdated`，自动使用框架快照。外部交易交付
成功或失败时，同时重新读取共享模拟后台快照，避免后台计数必须依赖手动刷新。
右上角刷新按钮保留，以便人工诊断网络或 App Store Connect 配置，不作为任何
流程的验收前置步骤。

## 并发、资源与错误边界

- 自动触发使用合并窗口，防止前台通知、交易和系统界面返回同时产生重复查询。
- 不使用固定频率轮询；无状态边界和外部事件时不唤醒 StoreKit。
- 刷新任务继承 PaymentClient 生命周期，取消后不得重新建立监听、提交快照或
  调用 `finish()`。
- 日志只包含触发原因、刷新强度、耗时和计数，不记录 JWS、账户令牌、完整交易
  ID 或 StoreKit 原始错误。
- 自动刷新失败不结束已完成交易，也不删除 outbox。

## 测试

框架回归测试先以失败状态覆盖：

1. 前台激活合并为一次完整刷新，`stop()` 后不刷新。
2. Storefront 更新重新加载价格和商品，监听结束后安全重连。
3. 交易更新完成后自动更新权益和订阅状态。
4. 到期、续订、宽限期和承诺边界触发轻量刷新。
5. 边界返回旧状态时有限退避，不形成无限循环。
6. 多来源并发触发被合并，较旧响应不能覆盖较新快照。
7. 自动刷新失败保留旧快照，后续触发可以恢复。

示例测试覆盖系统界面返回后的自动刷新、外部交易后的共享后台自动更新，以及
界面生命周期接入。StoreKitTest 覆盖自然到期、关闭自动续订、billing retry、
grace period、退款撤销和 Storefront 变化；真机 Sandbox 验收不得要求点击刷新。

2026-08-03 最终回归在 7 个套件中通过 174 项测试。真实 iPhone Sandbox 已验证
退款撤销、账单重试和恢复均沿用同一可靠交付路径，恢复后的两次冷启动都保持
pending 为 0。真机 Billing Grace Period 不作产品结论：App Store Connect 已保存
Sandbox-only 配置，但九个独立周期均由 Apple 直接返回 billing retry；只有实际
收到 `inGracePeriod` 和 `gracePeriodExpirationDate` 时才能将该路径记为真机通过。
