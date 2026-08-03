import Foundation

#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

/// 完整 Sandbox 优惠代码在系统剪贴板中的生命周期策略。
enum SandboxOfferCodeClipboardPolicy: Equatable {
    case clearIfUnchangedAfterPresentation
    case localOnly(expirationDate: Date)
}

/// Sandbox 优惠代码兑换使用的剪贴板边界。
@MainActor
protocol SandboxOfferCodeClipboard: AnyObject {
    /// 写入完整代码并返回写入后的系统变更计数。
    func store(
        _ value: String,
        policy: SandboxOfferCodeClipboardPolicy
    ) -> Int

    /// 仅当系统变更计数未改变时清空剪贴板。
    func clearIfUnchanged(after changeCount: Int)
}

/// 使用当前平台系统剪贴板保存 Sandbox 优惠代码。
@MainActor
final class SystemSandboxOfferCodeClipboard: SandboxOfferCodeClipboard {
    /// 写入完整代码并返回写入后的系统变更计数。
    func store(
        _ value: String,
        policy: SandboxOfferCodeClipboardPolicy
    ) -> Int {
#if os(iOS)
        switch policy {
        case .clearIfUnchangedAfterPresentation:
            UIPasteboard.general.string = value
        case .localOnly(let expirationDate):
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: value]],
                options: [
                    .localOnly: true,
                    .expirationDate: expirationDate
                ]
            )
        }
        return UIPasteboard.general.changeCount
#elseif os(macOS)
        guard case .clearIfUnchangedAfterPresentation = policy else {
            return NSPasteboard.general.changeCount
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        return NSPasteboard.general.changeCount
#endif
    }

    /// 仅当用户未改变剪贴板时清空刚写入的完整代码。
    func clearIfUnchanged(after changeCount: Int) {
#if os(iOS)
        // 只比较系统计数，绝不读取或记录剪贴板中的完整代码。
        guard UIPasteboard.general.changeCount == changeCount else { return }
        UIPasteboard.general.items = []
#elseif os(macOS)
        // 只比较系统计数，避免读取用户随后复制的新内容。
        guard NSPasteboard.general.changeCount == changeCount else { return }
        NSPasteboard.general.clearContents()
#endif
    }
}

/// 协调 Sandbox 优惠代码的临时剪贴板生命周期。
@MainActor
struct SandboxOfferCodeRedemptionCoordinator {
    private let clipboard: any SandboxOfferCodeClipboard

    /// 创建使用指定剪贴板的兑换协调器。
    init(clipboard: any SandboxOfferCodeClipboard) {
        self.clipboard = clipboard
    }

    /// 临时写入完整代码，展示系统兑换页，并在安全时清理剪贴板。
    func redeem(
        _ code: String,
        clipboardPolicy: SandboxOfferCodeClipboardPolicy =
            .clearIfUnchangedAfterPresentation,
        presentSystemSheet: @escaping @MainActor () async throws -> Void
    ) async throws {
        let changeCount = clipboard.store(code, policy: clipboardPolicy)
        let clearsAfterPresentation: Bool
        switch clipboardPolicy {
        case .clearIfUnchangedAfterPresentation:
            clearsAfterPresentation = true
        case .localOnly:
            clearsAfterPresentation = false
        }

        defer {
            if clearsAfterPresentation {
                // 展示成功、取消或失败时都执行同一项 changeCount 安全清理。
                clipboard.clearIfUnchanged(after: changeCount)
            }
        }
        try await presentSystemSheet()
    }
}
