# PaymentKit Sandbox 优惠代码 Bundle 配置设计

## 目标

在示例 App 中把 App Store Connect 下载的 Sandbox 一次性优惠代码作为版本化 Bundle 配置读取，并在年订阅商品卡的“购买优惠”菜单中手动选择。选择代码后，示例复制该代码并打开 Apple 系统兑换页；后续交易仍由 PaymentKit 的 StoreKit 2 监听、SQLite outbox 和幂等处理器可靠处理。

该能力只服务于开发和 Sandbox 真机测试，不进入 PaymentKit 框架公共 API，不用于生产优惠代码分发，也不授予任何业务权益。

## 安全边界

- 实际 `SandboxOfferCodes.csv` 是示例 App 的 Sandbox 测试配置，不加入 `.gitignore`，会出现在 Git 状态中并参与示例 App 构建。
- 该文件只能包含 App Store Connect 生成的 Sandbox 一次性代码，禁止放入生产优惠代码。
- 完整优惠代码只允许存在于该配置文件、示例 App Bundle、示例进程内存和用户明确操作产生的系统剪贴板中。
- 完整代码不得进入日志、错误、`PaymentEvent`、快照、SQLite outbox、共享模拟后台数据库、测试结果或崩溃诊断文本。
- PaymentKit 框架、`TransactionProcessor` 和共享模拟后台不读取优惠代码配置。
- Bundle 配置只适用于 Sandbox。真实生产 App 不应把可兑换代码打包到客户端。

## 配置与构建

本机配置文件固定为：

```text
Examples/LocalConfiguration/SandboxOfferCodes.csv
```

文件格式与 App Store Connect 下载文件一致：

- UTF-8 文本；
- 无表头；
- 每行一个代码；
- 允许 LF 或 CRLF；
- 允许空行和行首尾空白；
- 有效代码为 18 位 ASCII 字母或数字。

示例构建使用只属于主 App 的资源同步组：

1. 未被 Git 忽略的 `SandboxOfferCodes.csv` 自动复制到 App Bundle。
2. iOS 和 macOS 示例使用同一文件；Share Extension 不包含该文件。
3. 文件意外缺失时，示例仍按“未配置”安全降级，不影响普通购买。
4. README 明确该文件会被 Git 发现且仅包含 Sandbox 一次性代码，不得替换为生产代码。

## 示例内部组件

新增示例内部 `SandboxOfferCodeCatalog`，不放入 PaymentKit target。

其职责为：

- 从 Bundle 查找 `SandboxOfferCodes.csv`；
- 逐行解析、去除空白、校验格式并按输入顺序去重；
- 设置合理的文件大小和记录数量上限；
- 只报告有效、重复和无效记录数量，不返回原始无效文本；
- 为界面提供稳定的内存标识、序号和脱敏显示文本；
- 保留完整代码供用户明确点击兑换时使用。

商品与配置的绑定由示例完成：该本地代码目录只挂载到 `paymentkit.demo.yearly`。PaymentKit 不推断优惠代码对应的商品，也不把该绑定扩展为业务配置。

## 界面与交互

年订阅商品卡继续使用现有“购买优惠”菜单，选项顺序为：

1. 标准价格；
2. Apple 首购优惠；
3. 促销优惠或回归用户优惠；
4. Sandbox 优惠代码。

代码选项显示为：

```text
优惠代码 01 · ••••••••••••••A1B2
```

完整代码不得显示在菜单、辅助功能描述或调试描述中。序号用于区分末尾字符相同的代码。

选择优惠代码后：

- 年订阅账单计划切换为 `.upFront`，避免继续展示与该预付代码冲突的月付承诺方案；
- 商品价格和标准续订信息继续来自 StoreKit；
- 主操作按钮改为“复制并兑换优惠代码”；
- 不调用 `PaymentClient.purchase(...)`；
- 用户点击按钮后才把所选代码写入系统剪贴板并展示 Apple 优惠代码兑换页；
- 系统页关闭后执行现有 StoreKit 状态协调，重试 outbox、刷新快照和模拟后台计数；
- 若剪贴板 `changeCount` 与写入后一致，则清除剪贴板；若用户或其他 App 已修改剪贴板，则保留新内容且不读取其值。

App 无法从系统兑换页确认某个一次性代码是否完成兑换，因此不自动标记代码为“已使用”。代码最终是否有效由 App Store 决定。

## 缺失与错误处理

- 配置文件缺失：商品和其他优惠正常工作，菜单显示不可选的“未配置 Sandbox 优惠代码”。
- 文件为空或没有有效代码：行为与缺失文件相同。
- 部分行无效：保留有效代码，并仅显示“忽略 N 条无效配置”的非敏感诊断。
- 重复代码：只保留第一次出现的记录，仅报告重复数量。
- 文件过大、无法读取或编码无效：关闭本地代码能力，不影响 PaymentClient 启动、商品加载和购买。
- 没有可用展示场景：不写入剪贴板，返回中立界面错误。
- 系统兑换页失败：使用现有脱敏 `PaymentError`，不附加代码或 StoreKit 原始错误。

## 自动刷新与可靠交付

优惠代码只能通过 Apple 系统兑换入口使用。兑换产生的外部交易由现有 `Transaction.updates` 监听接收：

1. StoreKit 本地验证；
2. 写入 SQLite outbox；
3. 模拟后台幂等处理；
4. 标记已交付；
5. 调用 StoreKit `finish()`；
6. 删除 outbox；
7. 自动刷新商品、当前权益和订阅状态。

`PaymentAppliedOffer` 应显示 `.offerCode`。优惠代码本身不参与业务状态摘要，也不会被 StoreKit 交易模型返回给客户端。

## 测试

### 单元测试

- LF、CRLF、空行和前后空白；
- 输入顺序和去重；
- 非法字符、错误长度和无效编码；
- 空文件、文件大小上限和记录数量上限；
- 脱敏文本只包含序号和末四位；
- 选择代码后只能进入兑换路径，绝不调用普通购买；
- 剪贴板未变化时清除，发生变化时不清除；
- 缺失配置不影响普通购买；
- 日志、错误、事件、快照和数据库不包含测试代码。

自动测试使用注入的虚构 18 位代码，不依赖本机真实配置。

### 构建验收

- `swift test`、macOS 示例测试和 iOS Simulator 构建通过；
- iOS Sandbox 真机构建的 App Bundle 包含该资源；
- Share Extension Bundle 不包含该资源；
- `git check-ignore` 确认实际代码文件未被忽略，`git status` 能显示该文件；
- `git diff --check` 通过。

### 真机 Sandbox 验收

1. 年订阅菜单显示 10 条脱敏优惠代码。
2. 选择一条代码后按钮变为“复制并兑换优惠代码”。
3. 系统页可粘贴并兑换该代码。
4. 外部年订阅交易无需手动刷新即可出现。
5. 实际优惠显示为“优惠代码”。
6. outbox 最终清零，模拟后台业务交付只增加一次。
7. 强制结束并重启 App 后不重复业务交付。
8. 日志、SQLite 数据库和界面诊断不存在完整优惠代码。

## 非目标

- 不自动生成、下载或轮换 App Store Connect 优惠代码。
- 不通过普通 `Product.purchase` 传入优惠代码。
- 不持久保存代码使用状态。
- 不把真实生产优惠代码打包进客户端。
- 不修改 `ziia`、不提交 App Review，也不部署真实后台。
