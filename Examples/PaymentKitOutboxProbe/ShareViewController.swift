import Foundation
import PaymentKit
import UIKit

/// Share Extension 当前进程与共享账本的非敏感统计。
private struct ProbeBackendSnapshot: Sendable {
    let processedCount: Int
    let duplicateCount: Int
    let signedEventCount: Int
    let businessDeliveryCount: Int
}

/// Share Extension 使用的模拟后台。
///
/// 处理器与主 App 委托同一个 App Group SQLite 账本，不保存或授予会员、余额
/// 及其他业务权益。
private actor ProbeTransactionProcessor: TransactionProcessor {
    private let ledger: SharedMockBackendLedger
    private var processedCount = 0
    private var duplicateCount = 0
    private var pausesAfterCommit = false

    init(databaseURL: URL) {
        ledger = SharedMockBackendLedger(databaseURL: databaseURL)
    }

    /// 设置下一次后台提交后是否进入可控停顿。
    ///
    /// 该开关只在 Debug 构建中生效，用于真机稳定覆盖“后台已经提交，但客户端尚未
    /// 标记 delivered 或调用 finish”时扩展被强制结束的窗口。
    ///
    /// - Parameter pauses: `true` 时，下一次提交后暂停 15 秒。
    func setPausesAfterCommit(_ pauses: Bool) {
        #if DEBUG
        pausesAfterCommit = pauses
        #else
        pausesAfterCommit = false
        #endif
    }

    func process(_ transaction: PaymentTransaction) async throws {
        let acceptance = try await ledger.accept(transaction)
        #if DEBUG
        if pausesAfterCommit {
            // 共享账本已经原子提交；停顿发生在向 PaymentClient 返回成功之前。
            // 进程在此处被强杀后，下一进程必须依靠后台幂等重放完成后续状态机。
            pausesAfterCommit = false
            try await Task.sleep(nanoseconds: 15_000_000_000)
        }
        #endif
        switch acceptance {
        case .processed:
            processedCount += 1
        case .duplicate:
            duplicateCount += 1
        }
    }

    func snapshot() async -> ProbeBackendSnapshot {
        let statistics = try? await ledger.statistics()
        return ProbeBackendSnapshot(
            processedCount: processedCount,
            duplicateCount: duplicateCount,
            signedEventCount: statistics?.signedEventCount ?? 0,
            businessDeliveryCount: statistics?.businessDeliveryCount ?? 0
        )
    }
}

/// 从系统分享面板验证 App Group SQLite outbox 的探针界面。
final class ShareViewController: UIViewController {
    private let countLabel = UILabel()
    private let reportLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let postCommitPauseSwitch = UISwitch()
    private var client: PaymentClient?
    private var processor: ProbeTransactionProcessor?
    private var operationTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        configurePaymentClient()
    }

    deinit {
        operationTask?.cancel()
    }

    /// 构建不会展示任何敏感交易字段的探针界面。
    private func configureInterface() {
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "PaymentKit 共享 Outbox"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        countLabel.text = "正在读取处理前数量…"
        countLabel.font = .preferredFont(forTextStyle: .body)
        countLabel.adjustsFontForContentSizeCategory = true

        reportLabel.text = "尚未执行重试"
        reportLabel.font = .preferredFont(forTextStyle: .footnote)
        reportLabel.textColor = .secondaryLabel
        reportLabel.numberOfLines = 0
        reportLabel.adjustsFontForContentSizeCategory = true

        retryButton.configuration = .filled()
        retryButton.configuration?.title = "重试共享 outbox"
        retryButton.addTarget(self, action: #selector(retrySharedOutbox), for: .touchUpInside)
        retryButton.isEnabled = false

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("完成", for: .normal)
        closeButton.addTarget(self, action: #selector(completeExtension), for: .touchUpInside)

        var arrangedSubviews: [UIView] = [
            titleLabel,
            countLabel,
            reportLabel,
            retryButton,
            activityIndicator,
            closeButton,
        ]
        #if DEBUG
        let postCommitPauseLabel = UILabel()
        postCommitPauseLabel.text = "测试：后台提交后暂停 15 秒"
        postCommitPauseLabel.font = .preferredFont(forTextStyle: .footnote)
        postCommitPauseLabel.adjustsFontForContentSizeCategory = true
        let postCommitPauseRow = UIStackView(arrangedSubviews: [
            postCommitPauseLabel,
            postCommitPauseSwitch,
        ])
        postCommitPauseRow.axis = .horizontal
        postCommitPauseRow.alignment = .center
        postCommitPauseRow.spacing = 12
        arrangedSubviews.insert(postCommitPauseRow, at: 3)
        #endif

        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    /// 创建与主应用使用相同 App Group 和 namespace 的客户端。
    private func configurePaymentClient() {
        do {
            let databaseURL = try SharedMockBackendStorage.databaseURL(
                appGroupIdentifier: "group.com.paymentkit.examples"
            )
            let processor = ProbeTransactionProcessor(databaseURL: databaseURL)
            self.processor = processor
            client = try PaymentClient(
                configuration: PaymentConfiguration(productIDs: []),
                processor: processor,
                storage: .appGroup(
                    identifier: "group.com.paymentkit.examples",
                    namespace: "com.paymentkit.examples.payment-outbox"
                )
            )
        } catch {
            countLabel.text = "共享容器不可访问"
            reportLabel.text = "请检查扩展签名和 App Group entitlement。"
            return
        }

        operationTask = Task { [weak self, client] in
            guard let self, let client else { return }
            do {
                // refresh 只汇总共享记录；真正交付必须等待用户点击重试按钮。
                let snapshot = try await client.refresh()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.countLabel.text = "处理前：\(snapshot.pendingTransactions.count) 笔"
                    self.retryButton.isEnabled = true
                }
            } catch {
                await MainActor.run {
                    self.countLabel.text = "读取共享 outbox 失败"
                    self.reportLabel.text = "未执行任何交易交付。"
                }
            }
        }
    }

    /// 由明确的用户操作重试共享 outbox。
    @objc private func retrySharedOutbox() {
        guard let client, let processor else { return }
        #if DEBUG
        let pausesAfterCommit = postCommitPauseSwitch.isOn
        postCommitPauseSwitch.isEnabled = false
        #else
        let pausesAfterCommit = false
        #endif
        retryButton.isEnabled = false
        activityIndicator.startAnimating()
        reportLabel.text = pausesAfterCommit
            ? "正在重试；后台提交后将暂停 15 秒…"
            : "正在重试…"

        operationTask = Task { [weak self, client, processor] in
            await processor.setPausesAfterCommit(pausesAfterCommit)
            let report = await client.retryUnfinishedTransactions()
            let backendSnapshot = await processor.snapshot()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.activityIndicator.stopAnimating()
                self.retryButton.isEnabled = true
                self.postCommitPauseSwitch.isEnabled = true
                self.countLabel.text = "处理后：\(report.snapshot.pendingTransactions.count) 笔"
                self.reportLabel.text = """
                尝试 \(report.attemptedCount) · 交付 \(report.deliveredCount) · \
                finish \(report.finishedCount) · 等待 finish \(report.awaitingFinishCount) · \
                失败 \(report.failureCount)
                本次首次交付 \(backendSnapshot.processedCount) · \
                幂等命中 \(backendSnapshot.duplicateCount)
                共享签名事件 \(backendSnapshot.signedEventCount) · \
                业务交付 \(backendSnapshot.businessDeliveryCount)
                """
            }
        }
    }

    @objc private func completeExtension() {
        operationTask?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
