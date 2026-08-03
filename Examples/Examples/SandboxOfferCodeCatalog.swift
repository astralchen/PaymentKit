import Foundation

/// 供 Sandbox 示例展示的脱敏优惠代码。
nonisolated struct SandboxOfferCode: Identifiable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    /// 代码在已解析目录中的稳定序号。
    let id: Int

    /// 可安全显示给用户的脱敏代码名称。
    let displayName: String

    /// 完整优惠代码只保存在此私有字段中，避免日志和调试输出泄露。
    private let value: String

    /// 返回可安全展示的脱敏名称。
    var description: String { displayName }

    /// 返回可安全展示的脱敏名称。
    var debugDescription: String { displayName }

    /// 使用完整代码创建仅含末四位的展示名称。
    fileprivate init(id: Int, value: String) {
        self.id = id
        self.value = value
        displayName = "优惠代码 \(String(format: "%02d", id + 1)) · ••••••••••••••\(value.suffix(4))"
    }

    /// 仅限同一文件中的目录在兑换时读取完整代码。
    fileprivate var secretValue: String { value }
}

/// Sandbox 优惠代码目录的加载状态。
nonisolated enum SandboxOfferCodeCatalogStatus: Sendable, Equatable {
    case loaded
    case missing
    case empty
    case unreadable
    case invalidEncoding
    case fileTooLarge
    case tooManyRecords
}

/// Sandbox 优惠代码目录的安全解析结果。
nonisolated struct SandboxOfferCodeCatalog: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    /// 允许读取的最大文件大小（256 KiB）。
    static let maximumFileSize = 256 * 1024

    /// 允许解析的最大非空记录数。
    static let maximumRecordCount = 1_000

    /// 目录加载或解析的结果状态。
    let status: SandboxOfferCodeCatalogStatus

    /// 按输入顺序排列、已脱敏的有效优惠代码。
    let codes: [SandboxOfferCode]

    /// 被忽略的非法非空行数。
    let invalidLineCount: Int

    /// 被忽略的重复有效代码行数。
    let duplicateLineCount: Int

    /// 资源缺失时使用的安全空目录。
    static let missing = Self(
        status: .missing,
        codes: [],
        invalidLineCount: 0,
        duplicateLineCount: 0
    )

    /// 为 UI 测试提供不依赖实际 Bundle 内容的虚构目录。
    ///
    /// Release 构建会完全移除注入分支；Debug 构建也必须同时提供专用启动参数和环境
    /// 变量，普通本地或 Sandbox 启动仍读取 Bundle。
    static func loadForAppLaunch(
        from bundle: Bundle,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
#if DEBUG
        let fixtureKey = "PAYMENTKIT_UI_TEST_SANDBOX_OFFER_CODE_CATALOG"
        if arguments.contains("-PaymentKitUITestSandboxOfferCodeCatalog"),
           let fixture = environment[fixtureKey] {
            switch fixture {
            case "synthetic":
                return (try? parse(Data("UITESTCODE0000ABCD\n".utf8)))
                    ?? Self(
                        status: .unreadable,
                        codes: [],
                        invalidLineCount: 0,
                        duplicateLineCount: 0
                    )
            case "empty":
                return Self(
                    status: .empty,
                    codes: [],
                    invalidLineCount: 0,
                    duplicateLineCount: 0
                )
            default:
                break
            }
        }
#endif
        return load(from: bundle)
    }

    /// 从 Bundle 的文本资源加载 Sandbox 优惠代码目录。
    static func load(
        from bundle: Bundle,
        resourceName: String = "SandboxOfferCodes"
    ) -> Self {
        guard let url = bundle.url(forResource: resourceName, withExtension: "csv") else {
            return missing
        }

        do {
            let resourceValues = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard resourceValues.isRegularFile == true,
                  let fileSize = resourceValues.fileSize
            else {
                return Self(
                    status: .unreadable,
                    codes: [],
                    invalidLineCount: 0,
                    duplicateLineCount: 0
                )
            }
            guard fileSize <= maximumFileSize else {
                return Self(
                    status: .fileTooLarge,
                    codes: [],
                    invalidLineCount: 0,
                    duplicateLineCount: 0
                )
            }

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { try? fileHandle.close() }
            let data = try fileHandle.read(
                upToCount: maximumFileSize + 1
            ) ?? Data()
            return try parse(data)
        } catch let error as SandboxOfferCodeCatalogError {
            // 解析错误映射为稳定状态，不拼接任何底层错误或文件内容。
            return Self(
                status: error.status,
                codes: [],
                invalidLineCount: 0,
                duplicateLineCount: 0
            )
        } catch {
            // 读取异常同样不向调用方暴露底层错误文本。
            return Self(
                status: .unreadable,
                codes: [],
                invalidLineCount: 0,
                duplicateLineCount: 0
            )
        }
    }

    /// 解析 UTF-8 数据中的 Sandbox 优惠代码。
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumFileSize else {
            throw SandboxOfferCodeCatalogError.fileTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SandboxOfferCodeCatalogError.invalidEncoding
        }

        var codes: [SandboxOfferCode] = []
        var seenValues = Set<String>()
        var nonEmptyLineCount = 0
        var invalidLineCount = 0
        var duplicateLineCount = 0

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let value = String(rawLine).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            // 容量限制以输入记录计数，重复或非法行也不能绕过限制。
            nonEmptyLineCount += 1
            guard nonEmptyLineCount <= maximumRecordCount else {
                throw SandboxOfferCodeCatalogError.tooManyRecords
            }

            guard isValid(value) else {
                invalidLineCount += 1
                continue
            }
            guard seenValues.insert(value).inserted else {
                duplicateLineCount += 1
                continue
            }

            codes.append(SandboxOfferCode(id: codes.count, value: value))
        }

        return Self(
            status: codes.isEmpty ? .empty : .loaded,
            codes: codes,
            invalidLineCount: invalidLineCount,
            duplicateLineCount: duplicateLineCount
        )
    }

    /// 仅在需要兑换时按稳定序号取得私有保存的完整代码。
    func secretValue(for id: SandboxOfferCode.ID) -> String? {
        codes.first(where: { $0.id == id })?.secretValue
    }

    /// 返回仅含状态和统计信息的安全摘要。
    var description: String {
        "SandboxOfferCodeCatalog(status: \(status), codes: \(codes.count), invalidLineCount: \(invalidLineCount), duplicateLineCount: \(duplicateLineCount))"
    }

    /// 返回仅含状态和统计信息的安全摘要。
    var debugDescription: String { description }

    /// 验证完整代码为恰好 18 个 ASCII 字母或数字。
    private static func isValid(_ value: String) -> Bool {
        let utf8 = value.utf8
        return utf8.count == 18 && utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122:
                true
            default:
                false
            }
        }
    }
}

/// Sandbox 优惠代码目录的可预期解析错误。
nonisolated enum SandboxOfferCodeCatalogError: Error, Equatable {
    case invalidEncoding
    case fileTooLarge
    case tooManyRecords

    /// 将错误转换为不含底层详情的稳定目录状态。
    fileprivate var status: SandboxOfferCodeCatalogStatus {
        switch self {
        case .invalidEncoding:
            .invalidEncoding
        case .fileTooLarge:
            .fileTooLarge
        case .tooManyRecords:
            .tooManyRecords
        }
    }
}
