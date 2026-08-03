import SwiftUI

/// PaymentKit 本地 StoreKit 测试示例。
@main
struct ExamplesApp: App {
    @StateObject private var model: PaymentKitExampleModel

    init() {
        let initialModel: PaymentKitExampleModel
        do {
            initialModel = try PaymentKitExampleModel.live()
        } catch {
            // 共享容器不可访问时展示明确错误，绝不退回另一份正在工作的应用容器 outbox。
            initialModel = PaymentKitExampleModel.storageConfigurationFailure()
        }
        _model = StateObject(wrappedValue: initialModel)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
