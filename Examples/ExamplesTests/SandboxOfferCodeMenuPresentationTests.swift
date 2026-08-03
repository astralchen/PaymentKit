import Testing
@testable import Examples

@Suite("Sandbox 优惠代码菜单展示")
@MainActor
struct SandboxOfferCodeMenuPresentationTests {
    @Test("无有效代码只增加不可选占位且保留原优惠选择")
    func emptyCatalogKeepsStandardAndPromotionalOffersSelectable() {
        let originalOffers: [ExampleOfferChoice] = [
            .standard,
            .promotional("test-promotion"),
        ]

        let presentation = SandboxOfferCodeMenuPresentation(
            selectableOffers: originalOffers,
            hasValidSandboxOfferCodes: false
        )

        #expect(presentation.selectableOffers == originalOffers)
        #expect(
            presentation.unselectablePlaceholderText
                == "未配置 Sandbox 优惠代码"
        )
    }

    @Test("存在有效代码时不显示未配置占位")
    func configuredCatalogDoesNotShowPlaceholder() {
        let originalOffers: [ExampleOfferChoice] = [
            .standard,
            .sandboxOfferCode(id: 0, displayName: "虚构脱敏选项"),
        ]

        let presentation = SandboxOfferCodeMenuPresentation(
            selectableOffers: originalOffers,
            hasValidSandboxOfferCodes: true
        )

        #expect(presentation.selectableOffers == originalOffers)
        #expect(presentation.unselectablePlaceholderText == nil)
    }
}
