# PaymentKit Sandbox Offer Code Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在示例 App Bundle 中加载未被 Git 忽略的 Sandbox 优惠代码 CSV，并允许用户在年订阅“购买优惠”菜单中选择、复制并通过 Apple 系统页兑换。

**Architecture:** 新增仅属于 Examples target 的代码目录解析器和剪贴板协调器；`ExampleOfferChoice` 只保存非敏感代码序号与脱敏文案，完整代码由 Sandbox 配置和内存目录保存。实际 CSV 通过只属于主 App 的文件系统同步组进入 Bundle，且不加入 `.gitignore`；PaymentKit、outbox 和模拟后台不接触该配置。

**Tech Stack:** Swift 6、SwiftUI、StoreKit 2、UIKit/AppKit 系统剪贴板、Swift Testing、Xcode 文件系统同步组。

## Global Constraints

- 保持 iOS 15+、macOS 13+、Swift 6 严格并发和零第三方依赖。
- 只修改 `PaymentKit Sandbox MP8Z` 示例，不修改 `ziia`。
- 实际 CSV 不得被 Git 忽略，且只能包含 Sandbox 一次性代码；代码不得出现在该文件和 App Bundle 之外的日志、错误、事件、快照或 SQLite。
- 该能力只能存在于 Examples target；PaymentKit 公共 API、SQLite schema 和 `user_version` 不变。
- 年订阅代码活动固定绑定 `paymentkit.demo.yearly`；选择代码时切换到 `.upFront`，避免继续展示与该预付优惠冲突的月付承诺方案。
- 配置意外缺失时解析器必须安全降级；正常检出必须包含 CSV，自动测试和双平台构建必须通过。
- 当前工作区已有大量用户暂存修改；除非在隔离 worktree 执行，否则下面的提交步骤必须跳过，不得改变现有暂存区。

---

## File Structure

- Create `Examples/Examples/SandboxOfferCodeCatalog.swift`
  - 解析 Bundle CSV、限制容量、验证代码、生成脱敏模型。
- Create `Examples/Examples/SandboxOfferCodeRedemption.swift`
  - 封装 iOS/macOS 剪贴板写入与“未变化才清除”的协调逻辑。
- Create `Examples/ExamplesTests/SandboxOfferCodeCatalogTests.swift`
  - 目录解析、安全描述和边界测试。
- Create `Examples/ExamplesTests/SandboxOfferCodeRedemptionTests.swift`
  - 剪贴板清理和展示失败测试。
- Modify `Examples/Examples/PaymentKitExampleModel.swift`
  - 加载目录、扩展优惠选择、路由年订阅主操作。
- Modify `Examples/Examples/ContentView.swift`
  - 在现有菜单中展示脱敏代码并切换按钮语义。
- Modify `Examples/ExamplesTests/ExamplesTests.swift`
  - 增加主操作路由、菜单与安全边界结构回归测试。
- Modify `Examples/Examples.xcodeproj/project.pbxproj`
  - 增加只属于 Examples 主 App 的 `LocalConfiguration` 文件系统同步组。
- Create `Examples/LocalConfiguration/SandboxOfferCodes.csv`
  - 未被 Git 忽略、可纳入版本控制的 10 条 Sandbox 一次性代码配置。
- Modify `README.md`
  - 说明本地配置、Sandbox 安全边界和真机操作。
- Modify `.superpowers/sdd/2026-07-27-automatic-payment-state-refresh/progress.md`
  - 记录外部优惠代码交易的实际真机结果。

---

### Task 1: Sandbox 优惠代码目录解析器

**Files:**
- Create: `Examples/Examples/SandboxOfferCodeCatalog.swift`
- Create: `Examples/ExamplesTests/SandboxOfferCodeCatalogTests.swift`

**Interfaces:**
- Consumes: `Foundation.Bundle`、`Foundation.Data`。
- Produces:

```swift
struct SandboxOfferCode: Identifiable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    let id: Int
    let displayName: String
    var description: String { displayName }
    var debugDescription: String { displayName }
}

enum SandboxOfferCodeCatalogStatus: Sendable, Equatable {
    case loaded
    case missing
    case empty
    case unreadable
    case invalidEncoding
    case fileTooLarge
    case tooManyRecords
}

struct SandboxOfferCodeCatalog: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumFileSize = 256 * 1024
    static let maximumRecordCount = 1_000

    let status: SandboxOfferCodeCatalogStatus
    let codes: [SandboxOfferCode]
    let invalidLineCount: Int
    let duplicateLineCount: Int

    static let missing: Self

    static func load(
        from bundle: Bundle,
        resourceName: String = "SandboxOfferCodes"
    ) -> Self

    static func parse(_ data: Data) throws -> Self
    func secretValue(for id: SandboxOfferCode.ID) -> String?
}

enum SandboxOfferCodeCatalogError: Error, Equatable {
    case invalidEncoding
    case fileTooLarge
    case tooManyRecords
}
```

`SandboxOfferCode` 的完整值必须使用私有存储，公开描述只能返回 `displayName`。

- [ ] **Step 1: 写入目录解析失败测试**

在 `SandboxOfferCodeCatalogTests.swift` 增加：

```swift
import Foundation
import Testing
@testable import Examples

@Suite("Sandbox 优惠代码目录")
struct SandboxOfferCodeCatalogTests {
    @Test("按输入顺序解析、去空白并去重")
    func parsesInInputOrderAndDeduplicates() throws {
        let first = "A1B2C3D4E5F6G7H8I9"
        let second = "Z9Y8X7W6V5U4T3S2R1"
        let data = Data(" \(first) \r\n\n\(second)\n\(first)\n".utf8)

        let catalog = try SandboxOfferCodeCatalog.parse(data)

        #expect(catalog.status == .loaded)
        #expect(catalog.codes.map(\.id) == [0, 1])
        #expect(catalog.codes.map(\.displayName) == [
            "优惠代码 01 · ••••••••••••••H8I9",
            "优惠代码 02 · ••••••••••••••S2R1",
        ])
        #expect(catalog.duplicateLineCount == 1)
        #expect(catalog.invalidLineCount == 0)
        #expect(catalog.secretValue(for: 0) == first)
        #expect(catalog.secretValue(for: 1) == second)
    }

    @Test("忽略非法行但不暴露原始内容")
    func ignoresInvalidLinesWithoutExposingThem() throws {
        let valid = "A1B2C3D4E5F6G7H8I9"
        let data = Data("too-short\n含有中文字符0000000000\n\(valid)\n".utf8)

        let catalog = try SandboxOfferCodeCatalog.parse(data)

        #expect(catalog.codes.count == 1)
        #expect(catalog.invalidLineCount == 2)
        #expect(!catalog.description.contains("too-short"))
        #expect(!catalog.description.contains("含有中文"))
    }

    @Test("拒绝过大文件和过多记录")
    func enforcesCapacityLimits() throws {
        let oversized = Data(
            repeating: 0x41,
            count: SandboxOfferCodeCatalog.maximumFileSize + 1
        )
        #expect(throws: SandboxOfferCodeCatalogError.fileTooLarge) {
            try SandboxOfferCodeCatalog.parse(oversized)
        }

        let line = "A1B2C3D4E5F6G7H8I9\n"
        let tooMany = Data(
            String(
                repeating: line,
                count: SandboxOfferCodeCatalog.maximumRecordCount + 1
            ).utf8
        )
        #expect(throws: SandboxOfferCodeCatalogError.tooManyRecords) {
            try SandboxOfferCodeCatalog.parse(tooMany)
        }
    }
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ExamplesTests/SandboxOfferCodeCatalogTests \
  test
```

Expected: FAIL，提示 `SandboxOfferCodeCatalog`、`SandboxOfferCode` 尚不存在。

- [ ] **Step 3: 实现最小安全解析器**

在 `SandboxOfferCodeCatalog.swift` 中：

1. 先检查 `data.count <= 256 KiB`。
2. 使用 `String(data:encoding: .utf8)`，失败抛 `.invalidEncoding`。
3. 使用 `enumerateSubstrings(in:options: .byLines)` 或按换行拆分，非空行总数超过 1,000 时抛 `.tooManyRecords`。
4. 每行执行 `trimmingCharacters(in: .whitespacesAndNewlines)`。
5. 只接受 18 个 ASCII `A...Z`、`a...z`、`0...9`。
6. 使用 `Set<String>` 按输入顺序去重。
7. `SandboxOfferCode` 私有保存完整值，`displayName` 只包含两位序号和末四位。
8. 为 `SandboxOfferCodeCatalog` 实现脱敏 `description/debugDescription`，只返回状态和计数。
9. `load(from:)` 将缺失、读取失败和解析错误映射为稳定状态，不拼接底层错误。

- [ ] **Step 4: 补充缺失、空文件和无效 UTF-8 测试**

新增：

```swift
@Test("空文件返回 empty")
func emptyFileIsNonFatal() throws {
    let catalog = try SandboxOfferCodeCatalog.parse(Data())
    #expect(catalog.status == .empty)
    #expect(catalog.codes.isEmpty)
}

@Test("Bundle 缺少资源时安全返回 missing")
func missingBundleResourceIsNonFatal() {
    let catalog = SandboxOfferCodeCatalog.load(
        from: Bundle(for: MissingResourceMarker.self)
    )
    #expect(catalog.status == .missing)
    #expect(catalog.codes.isEmpty)
}

@Test("无效 UTF8 返回稳定错误")
func invalidUTF8FailsClosed() {
    #expect(throws: SandboxOfferCodeCatalogError.invalidEncoding) {
        try SandboxOfferCodeCatalog.parse(Data([0xC3, 0x28]))
    }
}

private final class MissingResourceMarker: NSObject {}
```

- [ ] **Step 5: 运行目录测试并确认 GREEN**

Run Task 1 Step 2 命令。

Expected: PASS，测试输出不包含任何完整 18 位测试代码。

- [ ] **Step 6: 创建隔离提交**

仅在隔离 worktree：

```bash
git add \
  Examples/Examples/SandboxOfferCodeCatalog.swift \
  Examples/ExamplesTests/SandboxOfferCodeCatalogTests.swift
git commit -m "feat: add sandbox offer code catalog"
```

当前共享脏工作区：跳过此步骤。

---

### Task 2: 版本化 Bundle 配置与主 App 资源隔离

**Files:**
- Modify: `Examples/Examples.xcodeproj/project.pbxproj`
- Create: `Examples/LocalConfiguration/SandboxOfferCodes.csv`
- Modify: `Examples/ExamplesTests/ExamplesTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `SandboxOfferCodeCatalog.load(from:)`。
- Produces: Examples 主 App Bundle 中可选的 `SandboxOfferCodes.csv`；Share Extension 永不包含该资源。

- [ ] **Step 1: 写入工程结构失败测试**

在 `ExamplesTests.swift` 增加只检查非敏感结构的测试：

```swift
@Test("Sandbox 优惠代码配置未被忽略且只属于主 App")
func sandboxOfferCodeResourceIsMainAppOnly() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let project = try String(
        contentsOf: repository
            .appendingPathComponent("Examples/Examples.xcodeproj/project.pbxproj"),
        encoding: .utf8
    )
    let configurationURL = repository.appendingPathComponent(
        "Examples/LocalConfiguration/SandboxOfferCodes.csv"
    )

    #expect(project.contains("LocalConfiguration"))
    #expect(
        project.components(
            separatedBy: "D70000000000000000000001 /* LocalConfiguration */"
        ).count == 4
    )
    #expect(FileManager.default.fileExists(atPath: configurationURL.path))
}
```

字符串出现三次的含义固定为：对象定义、根 group child、Examples target membership，因此 `components` 数量为四。扩展 target 不应出现第四次字符串。

- [ ] **Step 2: 运行结构测试并确认 RED**

Run:

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ExamplesTests/PaymentKitStoreKitTests/sandboxOfferCodeResourceIsMainAppOnly \
  test
```

Expected: FAIL，工程和版本化 CSV 尚未包含该配置。

- [ ] **Step 3: 增加只属于主 App 的文件系统同步组**

在 `project.pbxproj` 的 `PBXFileSystemSynchronizedRootGroup` 增加：

```text
D70000000000000000000001 /* LocalConfiguration */ = {
    isa = PBXFileSystemSynchronizedRootGroup;
    path = LocalConfiguration;
    sourceTree = "<group>";
};
```

将同一 ID：

- 加入根 `PBXGroup` children；
- 只加入 `770F621B... /* Examples */` 的 `fileSystemSynchronizedGroups`；
- 不加入 `PaymentKitOutboxProbe`、ExamplesTests 或 ExamplesUITests。

- [ ] **Step 4: 复制并版本化 App Store Connect Sandbox 文件**

不打印文件内容：

```bash
mkdir -p Examples/LocalConfiguration
cp \
  /Users/sondra/Downloads/OfferCodeOneTimeUseCodes_545498.csv \
  Examples/LocalConfiguration/SandboxOfferCodes.csv
test "$(wc -l < Examples/LocalConfiguration/SandboxOfferCodes.csv | tr -d ' ')" = "10"
test -z "$(git check-ignore Examples/LocalConfiguration/SandboxOfferCodes.csv)"
```

Expected: 10 行，且文件未被 Git 忽略。

- [ ] **Step 5: 验证主 App 包含且扩展不包含配置**

Run:

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme "Examples Sandbox" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/paymentkit-offer-code-device \
  build

test -f \
  /tmp/paymentkit-offer-code-device/Build/Products/Debug-iphoneos/Examples.app/SandboxOfferCodes.csv

test "$(
  wc -l \
    < /tmp/paymentkit-offer-code-device/Build/Products/Debug-iphoneos/Examples.app/SandboxOfferCodes.csv \
    | tr -d ' '
)" = "10"

test ! -f \
  /tmp/paymentkit-offer-code-device/Build/Products/Debug-iphoneos/Examples.app/PlugIns/PaymentKitOutboxProbe.appex/SandboxOfferCodes.csv
```

Expected: 主 App 有资源，扩展无资源。

- [ ] **Step 6: 运行结构测试并确认 GREEN**

Run Task 2 Step 2 命令。

Expected: PASS。

- [ ] **Step 7: 创建隔离提交**

仅在隔离 worktree：

```bash
git add \
  Examples/Examples.xcodeproj/project.pbxproj \
  Examples/LocalConfiguration/SandboxOfferCodes.csv \
  Examples/ExamplesTests/ExamplesTests.swift
git commit -m "build: support local sandbox offer code resource"
```

当前共享脏工作区：跳过此步骤。

---

### Task 3: 剪贴板安全协调与兑换路由

**Files:**
- Create: `Examples/Examples/SandboxOfferCodeRedemption.swift`
- Create: `Examples/ExamplesTests/SandboxOfferCodeRedemptionTests.swift`
- Modify: `Examples/Examples/PaymentKitExampleModel.swift`
- Modify: `Examples/ExamplesTests/ExamplesTests.swift`

**Interfaces:**
- Consumes:
  - `SandboxOfferCodeCatalog.codes`
  - `SandboxOfferCodeCatalog.secretValue(for:)`
  - `PaymentPresentation.presentOfferCodeRedeemSheet`
- Produces:

```swift
@MainActor
protocol SandboxOfferCodeClipboard: AnyObject {
    func store(_ value: String) -> Int
    func clearIfUnchanged(after changeCount: Int)
}

@MainActor
final class SystemSandboxOfferCodeClipboard: SandboxOfferCodeClipboard

@MainActor
struct SandboxOfferCodeRedemptionCoordinator {
    init(clipboard: any SandboxOfferCodeClipboard)

    func redeem(
        _ code: String,
        presentSystemSheet: @escaping @MainActor () async throws -> Void
    ) async throws
}

enum ExampleOfferChoice: Hashable, Identifiable {
    case standard
    case introductory
    case promotional(String)
    case winBack(String)
    case sandboxOfferCode(id: Int, displayName: String)
}
```

- [ ] **Step 1: 写入剪贴板协调失败测试**

创建：

```swift
import Testing
@testable import Examples

@Suite("Sandbox 优惠代码兑换协调")
@MainActor
struct SandboxOfferCodeRedemptionTests {
    @Test("系统页关闭且剪贴板未变化时清除")
    func clearsUnchangedClipboard() async throws {
        let clipboard = RecordingOfferCodeClipboard()
        let coordinator = SandboxOfferCodeRedemptionCoordinator(
            clipboard: clipboard
        )

        try await coordinator.redeem(
            "TESTCODE0000000001",
            presentSystemSheet: {}
        )

        #expect(clipboard.storedValue == nil)
        #expect(clipboard.clearCount == 1)
    }

    @Test("用户修改剪贴板后不清除新内容")
    func preservesChangedClipboard() async throws {
        let clipboard = RecordingOfferCodeClipboard()
        let coordinator = SandboxOfferCodeRedemptionCoordinator(
            clipboard: clipboard
        )

        try await coordinator.redeem(
            "TESTCODE0000000001",
            presentSystemSheet: {
                clipboard.simulateExternalChange("用户的新内容")
            }
        )

        #expect(clipboard.storedValue == "用户的新内容")
        #expect(clipboard.clearCount == 0)
    }

    @Test("系统展示失败也清理未变化的代码")
    func clearsAfterPresentationFailure() async {
        let clipboard = RecordingOfferCodeClipboard()
        let coordinator = SandboxOfferCodeRedemptionCoordinator(
            clipboard: clipboard
        )

        await #expect(throws: ExamplePresentationFailure.self) {
            try await coordinator.redeem(
                "TESTCODE0000000001",
                presentSystemSheet: { throw ExamplePresentationFailure() }
            )
        }
        #expect(clipboard.storedValue == nil)
    }
}

private struct ExamplePresentationFailure: Error {}

@MainActor
private final class RecordingOfferCodeClipboard: SandboxOfferCodeClipboard {
    private(set) var storedValue: String?
    private(set) var clearCount = 0
    private var changeCount = 0

    func store(_ value: String) -> Int {
        changeCount += 1
        storedValue = value
        return changeCount
    }

    func clearIfUnchanged(after expectedChangeCount: Int) {
        guard changeCount == expectedChangeCount else { return }
        changeCount += 1
        storedValue = nil
        clearCount += 1
    }

    func simulateExternalChange(_ value: String) {
        changeCount += 1
        storedValue = value
    }
}
```

测试 fake 的 `clearIfUnchanged` 必须只比较整数 `changeCount`，不能读取字符串内容。

- [ ] **Step 2: 运行测试并确认 RED**

Run:

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ExamplesTests/SandboxOfferCodeRedemptionTests \
  test
```

Expected: FAIL，协调器和协议尚不存在。

- [ ] **Step 3: 实现跨平台剪贴板协调器**

实现：

```swift
func redeem(
    _ code: String,
    presentSystemSheet: @escaping @MainActor () async throws -> Void
) async throws {
    let changeCount = clipboard.store(code)
    defer {
        clipboard.clearIfUnchanged(after: changeCount)
    }
    try await presentSystemSheet()
}
```

iOS 使用 `UIPasteboard.general`：

```swift
func store(_ value: String) -> Int {
    UIPasteboard.general.string = value
    return UIPasteboard.general.changeCount
}

func clearIfUnchanged(after changeCount: Int) {
    guard UIPasteboard.general.changeCount == changeCount else { return }
    UIPasteboard.general.items = []
}
```

macOS 使用 `NSPasteboard.general`，调用 `clearContents()`、`setString(_:forType:)`，并用 `changeCount` 执行同样的比较。不得读取剪贴板字符串。

- [ ] **Step 4: 扩展优惠选择且不保存完整代码**

修改 `ExampleOfferChoice`：

```swift
case sandboxOfferCode(id: Int, displayName: String)
```

其 `id` 必须为：

```swift
case .sandboxOfferCode(let id, _):
    "sandbox-offer-code:\(id)"
```

`displayName` 只返回关联的脱敏文案。

在 `PaymentKitExampleModel` 增加：

```swift
@Published private(set) var sandboxOfferCodeCatalog: SandboxOfferCodeCatalog
private let sandboxOfferCodeRedemption: SandboxOfferCodeRedemptionCoordinator
```

`live()` 从 `Bundle.main` 加载；`preview()` 使用 `.missing` 空目录；测试初始化器允许注入目录和 fake 剪贴板。

- [ ] **Step 5: 把代码选项加入年订阅并切换预付方案**

先把商品常量整理为：

```swift
enum ExampleProducts {
    static let yearly = "paymentkit.demo.yearly"

    static let all = [
        "paymentkit.demo.coins100",
        "paymentkit.demo.lifetime",
        "paymentkit.demo.pass30days",
        "paymentkit.demo.monthly",
        yearly,
    ]
}
```

`availableOffers(for:)` 在现有 StoreKit 选项之后，仅对
`ExampleProducts.yearly` 追加：

```swift
catalog.codes.map {
    .sandboxOfferCode(id: $0.id, displayName: $0.displayName)
}
```

`selectOffer(_:for:)` 遇到 `.sandboxOfferCode` 时把该商品账单计划设为 `.upFront`。

`purchaseOptions(for:)` 增加防御分支：

```swift
case .sandboxOfferCode:
    throw ExampleInputError.offerCodeRequiresSystemRedemption
```

这样即使以后错误调用普通购买，也不会把优惠代码路径映射为 `Product.purchase()`。

- [ ] **Step 6: 新增统一商品主操作路由**

新增：

```swift
func performPrimaryAction(for product: PaymentProduct) async {
    switch selectedOffer(for: product) {
    case .sandboxOfferCode(let id, _):
        await redeemSandboxOfferCode(id: id, for: product)
    default:
        await purchase(product)
    }
}
```

`redeemSandboxOfferCode` 必须：

1. 验证商品 ID 是 `paymentkit.demo.yearly`。
2. 从目录按非敏感整数 ID 查完整值。
3. 在写剪贴板之前取得有效 `UIWindowScene` 或 `NSViewController`。
4. 通过现有 `StoreKitPresentationSingleFlight` 执行。
5. 使用协调器写入、展示系统页并按 `changeCount` 清理。
6. 系统页关闭后调用 `reconcileAfterStoreKitPresentation()`。
7. 状态文案只写“Sandbox 优惠代码兑换页已关闭”，不包含尾号或完整代码。

- [ ] **Step 7: 写入主操作路由结构回归测试**

在 `ExamplesTests.swift` 增加：

```swift
@Test("Sandbox 优惠代码只走系统兑换而不走普通购买")
func sandboxOfferCodeUsesRedemptionRoute() throws {
    let source = try exampleModelSource()
    let primaryAction = method("performPrimaryAction", in: source)
    let purchaseOptions = method("purchaseOptions", in: source)

    #expect(primaryAction.contains("redeemSandboxOfferCode"))
    #expect(primaryAction.contains("await purchase(product)"))
    #expect(source.contains("ExampleProducts.yearly"))
    #expect(source.contains("selectedBillingPlans[productID] = .upFront"))
    #expect(source.contains("sandboxOfferCodeCatalog.codes.map"))
    #expect(
        purchaseOptions.contains("offerCodeRequiresSystemRedemption")
    )
    let redemption = method("redeemSandboxOfferCode", in: source)
    #expect(redemption.contains("reconcileAfterStoreKitPresentation"))
    let sceneGuard = try #require(
        redemption.range(of: "activeWindowScene")
            ?? redemption.range(of: "contentViewController")
    )
    let clipboardWrite = try #require(
        redemption.range(of: "sandboxOfferCodeRedemption.redeem")
    )
    #expect(sceneGuard.lowerBound < clipboardWrite.lowerBound)
}
```

- [ ] **Step 8: 运行 Task 3 测试并确认 GREEN**

Run Task 3 Step 2 命令，然后运行：

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ExamplesTests/PaymentKitStoreKitTests/sandboxOfferCodeUsesRedemptionRoute \
  test
```

Expected: 全部 PASS。

- [ ] **Step 9: 创建隔离提交**

仅在隔离 worktree：

```bash
git add \
  Examples/Examples/SandboxOfferCodeRedemption.swift \
  Examples/Examples/PaymentKitExampleModel.swift \
  Examples/ExamplesTests/SandboxOfferCodeRedemptionTests.swift \
  Examples/ExamplesTests/ExamplesTests.swift
git commit -m "feat: route sandbox offer code redemption"
```

当前共享脏工作区：跳过此步骤。

---

### Task 4: 年订阅菜单与脱敏交互

**Files:**
- Modify: `Examples/Examples/ContentView.swift`
- Modify: `Examples/ExamplesTests/ExamplesTests.swift`
- Modify: `Examples/ExamplesUITests/ExamplesUITests.swift`

**Interfaces:**
- Consumes:
  - `PaymentKitExampleModel.availableOffers(for:)`
  - `PaymentKitExampleModel.performPrimaryAction(for:)`
  - `ExampleOfferChoice.sandboxOfferCode(id:displayName:)`
- Produces: 与现有截图一致的“购买优惠”菜单和“复制并兑换优惠代码”按钮。

- [ ] **Step 1: 写入 SwiftUI 结构失败测试**

在 `ExamplesTests.swift` 增加：

```swift
@Test("年订阅菜单展示脱敏代码且按钮使用统一主操作")
func contentViewRoutesSandboxOfferCodeAction() throws {
    let source = try exampleContentViewSource()
    let productRow = try #require(
        source.range(of: "private struct ProductRow")
    )
    let rowSource = String(source[productRow.lowerBound...])

    #expect(rowSource.contains("case .sandboxOfferCode"))
    #expect(rowSource.contains("\"复制并兑换优惠代码\""))
    #expect(source.contains("model.performPrimaryAction(for: product)"))
    #expect(!source.contains("secretValue"))
    #expect(!source.contains("UIPasteboard"))
    #expect(!source.contains("NSPasteboard"))
}
```

- [ ] **Step 2: 运行结构测试并确认 RED**

Run:

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ExamplesTests/PaymentKitStoreKitTests/contentViewRoutesSandboxOfferCodeAction \
  test
```

Expected: FAIL，界面尚未包含新 case 和按钮。

- [ ] **Step 3: 接入菜单和主按钮**

修改 `productsSection` 的主操作闭包：

```swift
Task { await model.performPrimaryAction(for: product) }
```

`ProductRow.purchaseButtonTitle` 增加：

```swift
case .sandboxOfferCode:
    return "复制并兑换优惠代码"
```

现有 `Picker(...).pickerStyle(.menu)` 继续使用 `availableOffers`，因此代码选项自动获得截图中的勾选样式。不得在 View 中读取目录的完整值。

- [ ] **Step 4: 展示非敏感配置状态**

只在 `paymentkit.demo.yearly` 商品卡下显示：

- `.loaded` 且有有效代码：“Sandbox 优惠代码：N 条，仅用于测试”；
- `.missing/.empty`：“未配置 Sandbox 优惠代码”；
- 其他失败状态：“Sandbox 优惠代码配置不可用”；
- 有无效或重复行时只显示数量。

所有文案使用 `caption2` 和 `.secondary`，不显示文件路径、代码尾号以外内容或底层错误。

- [ ] **Step 5: 增加 UI 自动化标识**

为年订阅优惠 Picker 添加：

```swift
.accessibilityIdentifier("purchase-offer-paymentkit.demo.yearly")
```

为主按钮保留：

```swift
.accessibilityIdentifier("purchase-paymentkit.demo.yearly")
```

UI 测试只验证菜单存在和按钮可点击；真实代码选择与系统兑换页留给真机人工矩阵，避免把代码放入测试日志。

- [ ] **Step 6: 运行 Task 4 测试并确认 GREEN**

Run Task 4 Step 2 命令。

Expected: PASS。

- [ ] **Step 7: 运行示例完整 macOS 测试**

Run:

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Expected: 全部 PASS；实际 Sandbox CSV 不出现在测试输出。

- [ ] **Step 8: 创建隔离提交**

仅在隔离 worktree：

```bash
git add \
  Examples/Examples/ContentView.swift \
  Examples/ExamplesTests/ExamplesTests.swift \
  Examples/ExamplesUITests/ExamplesUITests.swift
git commit -m "feat: select sandbox codes from subscription menu"
```

当前共享脏工作区：跳过此步骤。

---

### Task 5: 文档、全量自动验收与真机 Sandbox

**Files:**
- Modify: `README.md`
- Modify: `.superpowers/sdd/2026-07-27-automatic-payment-state-refresh/progress.md`
- Verify only: `Examples/LocalConfiguration/SandboxOfferCodes.csv`

**Interfaces:**
- Consumes: Tasks 1–4 的完整示例功能。
- Produces: 可复现的接入文档、自动测试结果和真实优惠代码外部交易证据。

- [ ] **Step 1: 更新 README**

增加以下内容：

1. `Examples/LocalConfiguration/SandboxOfferCodes.csv` 是未被 Git 忽略的 Sandbox 一次性代码；
2. 更新代码批次时从 App Store Connect 下载文件，并替换：

   ```text
   Examples/LocalConfiguration/SandboxOfferCodes.csv
   ```

3. 文件只进入示例主 App Bundle，不进入 Share Extension；
4. 年订阅菜单选择代码后会自动切换预付方案；
5. 点击“复制并兑换优惠代码”，在 Apple 系统页粘贴；
6. 系统页关闭后按 `changeCount` 清理剪贴板；
7. 真实生产 App 不得打包可兑换代码；
8. 外部交易由监听器、outbox 和幂等后台处理，不调用普通购买。

- [ ] **Step 2: 运行 Swift Package 全量测试**

Run:

```bash
swift test
```

Expected: 所有 PaymentKit 和签名工具测试 PASS。

- [ ] **Step 3: 运行 Examples macOS 全量测试**

Run Task 4 Step 7 命令。

Expected: PASS。

- [ ] **Step 4: 构建 iOS Simulator**

Run:

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 构建并安装真机 Sandbox App**

Run:

```bash
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme "Examples Sandbox" \
  -destination 'id=00008030-001E69322223802E' \
  -derivedDataPath /tmp/paymentkit-offer-code-device \
  build

xcrun devicectl device install app \
  --device 00008030-001E69322223802E \
  /tmp/paymentkit-offer-code-device/Build/Products/Debug-iphoneos/Examples.app
```

Expected: 构建和安装成功。

- [ ] **Step 6: 执行真机优惠代码矩阵**

在 iPhone：

1. 打开 PaymentKit，记录基线 pending、共享签名事件和业务交付数量。
2. 滚动到年订阅。
3. 打开“购买优惠”菜单，确认 10 条代码只显示序号和末四位。
4. 选择第一条代码，确认账单计划切换为“预付”。
5. 点击“复制并兑换优惠代码”。
6. 在 Apple 系统页粘贴并确认年订阅、首年优惠价格和续订说明。
7. 完成兑换并返回 App。
8. 不点击刷新，等待交易监听自动更新。
9. 确认当前权益/订阅状态出现 `paymentkit.demo.yearly`。
10. 确认实际优惠显示“优惠代码”。
11. 确认 pending 最终为 0，业务交付只增加 1。
12. 强制结束并重启 App，确认计数不再增加且没有重复交付。

- [ ] **Step 7: 执行敏感信息扫描**

只输出配置文件之外的命中文件名，不输出代码：

```bash
test -z "$(
  rg \
    --fixed-strings \
    --files-with-matches \
    --patterns-from Examples/LocalConfiguration/SandboxOfferCodes.csv \
    --glob '!Examples/LocalConfiguration/SandboxOfferCodes.csv' \
    --glob '!docs/superpowers/plans/2026-07-27-sandbox-offer-code-bundle.md' \
    .
)"
```

Expected: 无命中文件。

另外确认：

```bash
test -z "$(git check-ignore Examples/LocalConfiguration/SandboxOfferCodes.csv)"
test -n "$(git status --short -- Examples/LocalConfiguration/SandboxOfferCodes.csv)"
git diff --check
```

Expected: 文件未被忽略、能出现在 Git 状态中、diff 检查通过。

- [ ] **Step 8: 更新真机验收记录**

在 progress 文档写入：

- 测试日期、设备与 iOS 版本；
- 优惠代码交易的脱敏 transaction suffix；
- 兑换前后 pending、签名事件和业务交付计数；
- 自动刷新耗时；
- `PaymentAppliedOffer == .offerCode`；
- 重启后无重复交付；
- 不写入代码本身。

- [ ] **Step 9: 最终验证**

重新执行：

```bash
swift test
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -testPlan "Examples Local" \
  -destination 'platform=macOS,arch=arm64' \
  test
xcodebuild \
  -project Examples/Examples.xcodeproj \
  -scheme Examples \
  -destination 'generic/platform=iOS Simulator' \
  build
git diff --check
```

Expected: 全部通过。

- [ ] **Step 10: 创建隔离提交**

仅在隔离 worktree：

```bash
git add \
  README.md \
  .superpowers/sdd/2026-07-27-automatic-payment-state-refresh/progress.md
git commit -m "docs: document sandbox offer code testing"
```

当前共享脏工作区：跳过此步骤。
