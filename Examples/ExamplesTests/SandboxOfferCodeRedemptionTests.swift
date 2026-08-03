import Foundation
import Testing
@testable import Examples

@Suite("Sandbox 优惠代码兑换协调")
@MainActor
struct SandboxOfferCodeRedemptionTests {
    @Test("系统 presenter 缺少有效上下文时稳定拒绝准备展示")
    func systemPresenterRejectsMissingPresentationContext() {
        var providerCallCount = 0
        let presenter = SystemSandboxOfferCodeRedeemSheetPresenter(
            contextProvider: {
                providerCallCount += 1
                return nil
            }
        )
        var producedPresentation = false

        do {
            _ = try presenter.preparedPresentation()
            producedPresentation = true
        } catch let error as ExampleInputError {
            #expect(
                error == .sandboxOfferCodePresentationUnavailable
            )
        } catch {
            Issue.record("系统 presenter 返回了非稳定的上下文错误")
        }

        #expect(providerCallCount == 1)
        #expect(!producedPresentation)
    }

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

    @Test("无关闭信号时使用本机限时剪贴板且不立即清理")
    func preservesExpiringLocalClipboard() async throws {
        let clipboard = RecordingOfferCodeClipboard()
        let coordinator = SandboxOfferCodeRedemptionCoordinator(
            clipboard: clipboard
        )
        let expirationDate = Date(timeIntervalSince1970: 1_000)

        try await coordinator.redeem(
            "TESTCODE0000000001",
            clipboardPolicy: .localOnly(expirationDate: expirationDate),
            presentSystemSheet: {}
        )

        #expect(
            clipboard.policy == .localOnly(expirationDate: expirationDate)
        )
        #expect(clipboard.clearCount == 0)
    }
}

private struct ExamplePresentationFailure: Error {}

@MainActor
private final class RecordingOfferCodeClipboard: SandboxOfferCodeClipboard {
    private(set) var storedValue: String?
    private(set) var clearCount = 0
    private(set) var policy: SandboxOfferCodeClipboardPolicy?
    private var changeCount = 0

    func store(
        _ value: String,
        policy: SandboxOfferCodeClipboardPolicy
    ) -> Int {
        self.policy = policy
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
