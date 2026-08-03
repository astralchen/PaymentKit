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

    @Test("空文件返回 empty")
    func emptyFileIsNonFatal() throws {
        let catalog = try SandboxOfferCodeCatalog.parse(Data())
        #expect(catalog.status == .empty)
        #expect(catalog.codes.isEmpty)
    }

    @Test("从 Bundle 加载 CSV 资源并返回脱敏结果")
    func loadsCSVBundleResource() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.paymentkit.tests.sandbox-offer-codes",
            "CFBundleName": "SandboxOfferCodesFixture",
        ]
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        #expect((info as NSDictionary).write(to: infoURL, atomically: true))

        let value = "A1B2C3D4E5F6G7H8I9"
        let resourceURL = resourcesURL.appendingPathComponent("SandboxOfferCodes.csv")
        try Data("\(value)\n".utf8).write(to: resourceURL)
        let bundle = try #require(Bundle(url: bundleURL))

        let catalog = SandboxOfferCodeCatalog.load(from: bundle)

        #expect(catalog.status == .loaded)
        #expect(catalog.codes.map(\.displayName) == [
            "优惠代码 01 · ••••••••••••••H8I9",
        ])
    }

    @Test("Bundle 缺少资源时安全返回 missing")
    func missingBundleResourceIsNonFatal() {
        let catalog = SandboxOfferCodeCatalog.load(
            from: Bundle(for: MissingResourceMarker.self)
        )
        #expect(catalog.status == .missing)
        #expect(catalog.codes.isEmpty)
    }

    @Test("UI 测试虚构目录必须同时提供专用参数和环境变量")
    func uiTestFixtureRequiresBothLaunchControls() {
        let bundle = Bundle(for: MissingResourceMarker.self)
        let argument = "-PaymentKitUITestSandboxOfferCodeCatalog"
        let environmentKey =
            "PAYMENTKIT_UI_TEST_SANDBOX_OFFER_CODE_CATALOG"

        let injected = SandboxOfferCodeCatalog.loadForAppLaunch(
            from: bundle,
            arguments: [argument],
            environment: [environmentKey: "synthetic"]
        )
        let argumentOnly = SandboxOfferCodeCatalog.loadForAppLaunch(
            from: bundle,
            arguments: [argument],
            environment: [:]
        )
        let environmentOnly = SandboxOfferCodeCatalog.loadForAppLaunch(
            from: bundle,
            arguments: [],
            environment: [environmentKey: "synthetic"]
        )

        #expect(injected.status == .loaded)
        #expect(
            injected.codes.map(\.displayName)
                == ["优惠代码 01 · ••••••••••••••ABCD"]
        )
        #expect(argumentOnly.status == .missing)
        #expect(environmentOnly.status == .missing)
    }

    @Test("Bundle 超大资源在读取内容前按文件大小拒绝")
    func oversizedBundleResourceIsRejectedBeforeRead() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources")
        let resourceURL = resourcesURL.appendingPathComponent(
            "OversizedSandboxOfferCodes.csv"
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: resourceURL.path
            )
            try? FileManager.default.removeItem(at: bundleURL)
        }

        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.paymentkit.tests.oversized-offer-codes",
            "CFBundleName": "OversizedSandboxOfferCodesFixture",
        ]
        #expect(
            (info as NSDictionary).write(
                to: bundleURL.appendingPathComponent("Contents/Info.plist"),
                atomically: true
            )
        )
        #expect(FileManager.default.createFile(atPath: resourceURL.path, contents: nil))
        let fileHandle = try FileHandle(forWritingTo: resourceURL)
        try fileHandle.truncate(
            atOffset: UInt64(SandboxOfferCodeCatalog.maximumFileSize + 1)
        )
        try fileHandle.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: resourceURL.path
        )
        let bundle = try #require(Bundle(url: bundleURL))

        let catalog = SandboxOfferCodeCatalog.load(
            from: bundle,
            resourceName: "OversizedSandboxOfferCodes"
        )

        #expect(catalog.status == .fileTooLarge)
        #expect(catalog.codes.isEmpty)
    }

    @Test("无效 UTF8 返回稳定错误")
    func invalidUTF8FailsClosed() {
        #expect(throws: SandboxOfferCodeCatalogError.invalidEncoding) {
            try SandboxOfferCodeCatalog.parse(Data([0xC3, 0x28]))
        }
    }
}

private final class MissingResourceMarker: NSObject {}
