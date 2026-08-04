# `willAutoRenew` 语义、陈旧状态与生产级收敛

本文说明 StoreKit 2 中两个同名 `willAutoRenew` 的区别、为什么系统订阅页已经显示
“已取消订阅”而 App 仍可能短暂显示“将自动续订”，以及 PaymentKit 的客户端、
服务器端和测试处理规则。

## 结论

1. **当前权益和未来续订是两个独立维度。** 用户关闭自动续订后，已经支付的当前
   周期仍然有效，直到交易的 `expirationDate` 到达。不得因为
   `willAutoRenew == false` 立即撤销权益。
2. **普通预付订阅只用外层字段判断下一次续订。** 当交易的
   `billingPlanType == .upFront`，包括普通月订阅和一次付清的年订阅，读取
   `PaymentRenewalInfo.willAutoRenew`。`commitment` 应为 `nil`，不能读取或推断
   内层状态。
3. **只有月付、12 个月承诺计划同时存在两个续订层级。** 当
   `billingPlanType == .monthly`：
   - 外层 `PaymentRenewalInfo.willAutoRenew` 表示当前承诺中的下一笔月度账单是否
     继续；
   - 内层 `PaymentRenewalInfo.commitment?.willAutoRenew` 表示当前 12 个月承诺
     完成后，是否开始下一轮完整承诺。
4. **StoreKit 查询结果是 App Store 签名状态快照，不保证系统设置页关闭后立即在
   所有设备 API 上可见。** Sandbox 尤其可能重复返回同一份陈旧续订 JWS。重复查询、
   切换网络或重启 App 不能保证刷新这份账户状态。
5. **正常路径自动刷新，显式恢复用于兜底。** PaymentKit 不会在启动或前台切换时
   静默调用 `AppStore.sync()`；只有用户点击“恢复购买”后，
   `restorePurchases()` 才执行系统同步，因为该操作可能要求 Apple 账户认证。
6. **生产后台应作为业务状态的最终权威。** 使用 App Store Server Notifications
   V2 接收续订意愿变化，并用 App Store Server API 查询和校验最新订阅状态。客户端
   StoreKit 快照用于及时更新界面和离线体验，不能替代服务器验签与幂等状态机。

## 两个 `willAutoRenew` 的判定矩阵

| 账单计划 | 场景 | 外层 `renewalInfo.willAutoRenew` | 内层 `commitment.willAutoRenew` | 正确解释 |
| --- | --- | --- | --- | --- |
| 预付 `.upFront` | 普通月/年订阅正常续订 | `true` | `nil` | 当前周期结束后自动续订 |
| 预付 `.upFront` | 用户关闭自动续订 | `false` | `nil` | 当前权益保留至到期，之后不续订 |
| 月付承诺 `.monthly` | 承诺期正常进行 | `true` | `true` | 下一月继续扣款，承诺结束后再续一轮 |
| 月付承诺 `.monthly` | 用户取消下一轮承诺 | `true` | `false` | 剩余月度账单继续，承诺结束后不再开启新一轮 |
| 月付承诺 `.monthly` | 当前月扣款失败 | 依 StoreKit 状态 | 不能单独决定权益 | 结合交易、billing retry 和撤销状态处理 |

Apple 对外层字段的定义是“订阅是否在下一个周期自动续订”。对月付承诺计划，Apple
进一步规定：用户在承诺期内取消时，外层仍为 `true`，因为剩余月度账单继续；内层
变为 `false`，表示不开始下一轮 12 个月承诺。

因此，普通预付年订阅出现以下组合才是正确的取消状态：

```text
transaction.billingPlanType = .upFront
renewalInfo.willAutoRenew = false
renewalInfo.commitment = nil
transaction.expirationDate > now  // 当前权益仍然有效
```

界面可以同时显示“已取消订阅 / 不会自动续订”和“可使用至某日”。这不是状态矛盾。

## 2026-07-30 真机问题的缘由

测试场景是一笔已一次性付清的标准年订阅。Apple 系统订阅管理页已经显示
“已取消订阅”和“续期”按钮，但 App 仍显示“将自动续订”。

排查得到以下证据：

1. 交易账单计划为预付，因此正确字段是外层
   `renewalInfo.willAutoRenew`，不是 `commitmentInfo.willAutoRenew`。
2. 订阅组查询、`Product.SubscriptionInfo.Status.all` 状态序列、
   `Status.updates` 和 iOS 18.4+ 按交易 ID 查询均返回外层
   `willAutoRenew == true`。
3. 返回值通过 StoreKit 验签，且不同查询入口携带的是同一陈旧续订状态；客户端没有
   收到签署时间更新且值为 `false` 的 renewal JWS。
4. 切换网络、等待约 7 分钟和冷启动仍得到旧值。原因不在普通 App 网络请求，而在
   StoreKit/App Store 账户状态尚未向当前设备查询面收敛。
5. 用户明确点击“恢复购买”，`AppStore.sync()` 成功后，外层字段立即变为
   `false`；首次启动和强制退出后的冷启动都稳定显示“不会自动续订”。

可证实的根因边界是：**当前设备的 StoreKit Sandbox 查询持续提供陈旧但签名有效的
续订信息**。无法仅凭公共 API 进一步区分这是设备 `storekitd` 缓存、Sandbox 传播
延迟还是二者共同导致，因此文档和代码不把它伪装成应用字段映射错误。

这也解释了几个容易误判的现象：

- **为什么切换网络无效：** App 没有直接请求自己的 HTTP 接口；状态由 StoreKit
  账户服务和本地缓存共同提供。
- **为什么重复刷新无效：** 多个 StoreKit 查询入口可能读取同一份签名快照，轮询只
  会重复得到旧值。
- **为什么不能看到系统页就在 App 内强制写 `false`：** App 无法验证用户在系统页
  做了什么，也可能刚刚重新开启续订；推断会制造更严重的错误状态。
- **为什么 `signedDate` 重要但不能修复本次缓存：** 它能阻止较旧查询覆盖已经收到的
  较新事件；如果设备从未拿到新 JWS，就没有可合并的 `false` 值。

## PaymentKit 客户端解决方案

PaymentKit 使用以下层级收敛客户端状态：

1. 启动和刷新使用 `Product.SubscriptionInfo.status(for:)` 主动加载当前订阅组状态。
2. 所有支持系统使用 `Product.SubscriptionInfo.Status.updates` 长期监听后续变化；
   `Status.all` 仅枚举当前快照，完成后会正常结束，不得用于长期监听。
3. 应用回到前台、系统订阅管理页关闭、交易更新和订阅时间边界都会触发状态刷新。
4. 使用 renewal JWS 的 `signedDate` 合并状态事件和主动查询，避免较旧的订阅组
   查询覆盖较新的关闭续订事件；较新的主动查询会淘汰较旧事件缓存。
5. iOS 18.4+ 使用按交易 ID 的订阅状态查询交叉校验订阅组查询结果。
6. `Status.updates` 意外结束时有限退避重建；`stop()` 后停止重连和提交。
7. 所有自动路径都只接受 StoreKit 验签成功的数据，不根据文案、按钮、等待时间或
   网络变化猜测 `willAutoRenew`。

主动查询返回空时，客户端不会仅凭一次空结果删除已验签的 `Status.updates` 缓存。
空结果既可能表示当前账户没有该订阅，也可能是 StoreKit 暂时未返回状态；公共 API
没有账户标识可供客户端安全区分。需要跨账户收敛时必须使用下述显式会话边界。

### Apple 账户切换与会话级缓存

StoreKit 没有公开的 Apple 账户切换通知。2026-07-31 的 iPhone SE Sandbox 测试中，
旧实现中，账户 A 的 `Product.SubscriptionInfo.Status.all` 状态被保存在会话缓存；
切换到无购买历史的账户 B 后，普通查询返回空，但客户端仍保留 A 的已验签事件。
当前权益始终为 0，因此没有错误授予访问权限，但界面继续显示 A 的已过期订阅状态。
冷启动后状态消失，证明残留来自进程内的 `cachedSubscriptionStatusUpdates`，不是
持久化 outbox。当前实现所有版本统一按签署时间合并 `status(for:)` 快照和
`Status.updates` 单条事件。

生产修复使用显式商店会话热重载：

```swift
let snapshot = await client.reloadStoreSession()
```

该 API 等价于在同一进程内安全执行一次 `stop()` → `start()`：取消旧生命周期、
清除账户会话级订阅缓存、重建 StoreKit 状态/交易/Storefront 等异步序列，然后重放
unfinished 交易并完整刷新。它具有以下边界：

- 不调用 `AppStore.sync()`，不会主动显示账户认证；
- 不清除 SQLite outbox，不破坏幂等交付；
- 新会话成功提交前保留最近已验证快照，弱网和离线不会被误判为权益消失；
- 已知 StoreKit 系统流程关闭后可以调用；
- 不应在每次应用激活时无条件重载，否则会无意义地重建监听并增加 StoreKit 压力。

上述方案解决的是“新状态已经到达，但旧查询覆盖了它”及“单一查询面短暂不一致”。
它不能强制 StoreKit 把运行中进程从旧 Apple 账户重新绑定到新账户，也无法从一份仍
为 `true` 的签名快照推导出 `false`。2026-07-31 的 iPhone SE Sandbox 复测中，
A → B 后普通前台刷新和 `reloadStoreSession()` 都继续返回 A 的 non-consumable
权益。对于完全发生在 App 外的账户切换，必须提供明确的“恢复购买”入口：

```swift
// 必须由用户点击触发；可能显示 Apple 账户认证界面。
let snapshot = try await client.restorePurchases()
```

`restorePurchases()` 调用 `AppStore.sync()`。同步成功后停止旧会话，清除会话级
订阅事件和原始交易缓存，重建交易、订阅状态、Storefront 等长期监听，重放
unfinished/outbox，再执行受新生命周期约束的完整刷新。同步失败时保持旧会话和最后
有效快照。不得在启动、定时器、前台通知或订阅管理页返回时自动调用，否则可能无故
弹出系统认证界面。

2026-07-31 的后续 iPhone SE 复测还发现一个独立问题：B → A 返回应用时，
StoreKit 会短暂通过 `Transaction.unfinished` 暴露 A 的历史交易，但普通完整刷新只把
它汇总成“等待后台交付”，不会调用业务处理器；随后 StoreKit 不再返回该瞬时项时，
如果没有新的刷新触发，界面会一直保留待处理 1。此时 SQLite outbox 和模拟后端都为
0，证明并非后台交付卡住。

修复后，应用进入前台的自动刷新批次会先重放 newly-discovered unfinished，再提交
完整快照；公开 `refresh()` 仍保持只读汇总语义。重放受当前生命周期约束，不会调用
`AppStore.sync()`，并继续遵守 SQLite outbox、幂等业务交付和最后 `finish()` 的可靠
顺序。v4 真机结果为：B 显式恢复后权益/订阅/待处理均为 0；B → A 无冷启动返回后，
年订阅正确显示已过期、待处理保持 0、outbox 为 0，后端只有 1 次业务交付；再次
后台/前台后交付计数仍为 1。

如果显式同步仍未收敛：

1. 保留最近一份已验证快照，不伪造取消状态；
2. 提示用户稍后重试或打开系统订阅管理页确认；
3. 由生产后台查询最新状态并返回给 App；
4. Sandbox 验收可换用全新测试账号；如需“清除购买历史记录”，必须先取得明确同意，
   因为该操作会不可逆地删除测试历史，清除后还需退出并重新登录 Sandbox 账号；
5. 保存脱敏的环境、账单计划、续订 JWS `signedDate`、查询路径和时间线，向 Apple
   Feedback Assistant 提交可复现问题。

## 生产服务器解决方案

客户端恢复入口不能替代服务器状态机。生产后台应当：

1. 接收 App Store Server Notifications V2。
2. 对
   `DID_CHANGE_RENEWAL_STATUS/AUTO_RENEW_DISABLED` 和
   `AUTO_RENEW_ENABLED` 验签、去重并更新续订意愿。
3. 对标准预付订阅读取 JWS renewal info 的 `autoRenewStatus`：
   - `0`：关闭自动续订；
   - `1`：开启自动续订。
4. 对月付承诺计划先检查 `billingPlanType == MONTHLY`，再分别保存月度账单续订状态和
   `commitmentAutoRenewStatus`，不能覆盖成一个布尔值。
5. 通知缺失、乱序或状态冲突时，以任意已知 transaction ID 调用
   **Get All Subscription Statuses**，验证返回 JWS 后重建该用户的订阅组状态。
6. 权益仍按已验证交易的到期、撤销、升级和宽限期状态决定；续订意愿只用于展示未来
   是否续订、留存流程和到期后的状态转换。
7. 按环境、original transaction ID、notification UUID/JWS identity 和签署时间实现
   幂等与顺序保护，Sandbox 和 Production 数据严格隔离。

推荐的数据模型至少分开保存：

```text
entitlementState          // 当前是否有权访问
currentPeriodExpiresAt    // 当前权益何时到期
billingPlanType           // BILLED_UPFRONT 或 MONTHLY
periodWillAutoRenew       // 外层：下一账期
commitmentWillAutoRenew   // 内层：下一完整承诺；非承诺计划为 null
renewalInfoSignedAt       // Apple 签署时间
environment               // Sandbox 或 Production
```

## 界面规则

- 预付订阅：
  - 外层为 `true`：显示“将自动续订”；
  - 外层为 `false` 且当前交易未到期：显示“已取消订阅，将于 … 到期”；
  - 到期且无其他有效交易：显示“已过期”。
- 月付承诺计划必须分别显示：
  - “当前承诺：剩余 N 期继续按月付款”；
  - “下一承诺：将续订 / 已取消”。
- `autoRenewPreference` 只在外层 `willAutoRenew == true` 时作为下一商品的补充信息。
  关闭续订后即使 Sandbox 暂时返回非空 preference，也不能显示成仍会续订。
- 不要用 `willAutoRenew` 决定当前权益，也不要用当前权益存在推断自动续订仍开启。
- 显式同步期间可以显示“正在与 App Store 同步”；认证取消或失败时保留最后有效状态，
  不先清空权益。

## 验收步骤

### 自动收敛

1. 使用专用 Sandbox 账号购买标准预付年订阅。
2. 先在 App 中确认账单计划为“预付”、外层状态为“将自动续订”。
3. 打开 Apple 系统订阅管理页，关闭自动续订并返回 App。
4. 不点击诊断刷新，等待 App 的系统界面返回协调和状态监听。
5. 断言同一商品标识下显示“不会自动续订”，当前权益仍保留且 pending 为 0。
6. 强制结束并重启 App，再次断言状态不倒退。

### Sandbox 陈旧状态兜底

如果系统页已经显示取消，但 30 秒后 App 仍显示自动续订：

1. 记录所有客户端查询的 renewal JWS `signedDate` 和外层值；
2. 由用户点击“恢复购买”并完成可能出现的系统认证；
3. 断言外层变为 `false`；
4. 强制结束并重启，断言仍为 `false`；
5. 若仍失败，改用全新 Sandbox 账号或在明确授权后重置购买历史，并提交 Apple
   Feedback；不得修改断言形成假绿。

2026-07-30 的 iPhone SE 真机验收中，显式同步后的预付年订阅在首次启动和冷启动均
显示“不会自动续订”，账单计划仍为“预付”，当前权益保留，pending 为 0。对应结果：

```text
/private/tmp/PaymentKit-Sandbox-YearlyUpFront-AfterExplicitSync-20260730.xcresult
```

## Apple 官方资料

- [`RenewalInfo.willAutoRenew`](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalinfo/willautorenew)
- [管理月付 12 个月承诺订阅生命周期](https://developer.apple.com/documentation/storekit/managing-lifecycle-of-monthly-subscriptions-with-a-12-month-commitment-)
- [`AppStore.sync()`](https://developer.apple.com/documentation/storekit/appstore/sync%28%29)
- [测试关闭自动续订](https://developer.apple.com/documentation/storekit/testing-disabling-auto-renew)
- [App Store Server Notifications V2 `notificationType`](https://developer.apple.com/documentation/appstoreservernotifications/notificationtype)
- [App Store Server API `autoRenewStatus`](https://developer.apple.com/documentation/appstoreserverapi/autorenewstatus)
- [Get All Subscription Statuses](https://developer.apple.com/documentation/appstoreserverapi/get-all-subscription-statuses)
- [管理 Sandbox Apple 账户设置](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/manage-sandbox-apple-account-settings/)
