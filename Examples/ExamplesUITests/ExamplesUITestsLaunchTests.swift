import XCTest

/// 为不同界面配置保留示例程序启动截图。
final class ExamplesUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 启动示例并附加首屏截图。
    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        _ = app.staticTexts["status-message"].waitForExistence(timeout: 10)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "PaymentKit 示例首屏"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
