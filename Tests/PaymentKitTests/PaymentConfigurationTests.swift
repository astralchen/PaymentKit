import Foundation
import StoreKit
import Testing
@testable import PaymentKit

@Suite("支付配置")
struct PaymentConfigurationTests {
    @Test("商品标识符保持顺序并移除重复项")
    func productIdentifierOrder() {
        let configuration = PaymentConfiguration(
            productIDs: ["coins", "premium", "coins", "monthly", "premium"]
        )

        #expect(configuration.productIDs == ["coins", "premium", "monthly"])
    }

    @Test("未知商品类型保留原始值")
    func unknownProductType() {
        let type = PaymentProductType(rawValue: "future-product")

        #expect(type == .unknown("future-product"))
        #expect(type.rawValue == "future-product")
    }

    @Test("未知 StoreKit 枚举保留原始值")
    func unknownStoreKitValues() {
        #expect(PaymentOwnershipType.unknown("future-owner") == .unknown("future-owner"))
        #expect(PaymentSubscriptionOffer.PaymentMode.unknown("future-mode") == .unknown("future-mode"))
        #expect(PaymentRenewalState.unknown(99) == .unknown(99))
        #expect(PaymentExpirationReason.unknown(100) == .unknown(100))
    }

    @Test("购买选项提供安全默认值")
    func purchaseOptionDefaults() {
        let options = PurchaseOptions()

        #expect(options.quantity == 1)
        #expect(options.appAccountToken == nil)
        #expect(options.simulatesAskToBuyInSandbox == false)
        #expect(options.billingPlan == nil)
        #expect(options.offer == nil)
    }

    @Test("首购和促销授权的调试描述始终脱敏")
    func offerAuthorizationsAreOpaque() {
        let introductoryJWS = "header.sensitive-intro-payload.signature"
        let promotionalJWS = "header.sensitive-promo-payload.signature"
        let eligibility = PaymentIntroductoryOfferEligibility(compactJWS: introductoryJWS)
        let authorization = PaymentPromotionalOfferAuthorization(
            offerID: "retention",
            compactJWS: promotionalJWS
        )
        let introductory = PurchaseOptions(
            offer: .introductory(eligibility: eligibility)
        )
        let promotional = PurchaseOptions(
            offer: .promotional(authorization: authorization)
        )

        #expect(eligibility.debugDescription == "<PaymentIntroductoryOfferEligibility: redacted>")
        #expect(
            authorization.debugDescription
                == "<PaymentPromotionalOfferAuthorization offerID=retention authorization=redacted>"
        )
        #expect(!String(reflecting: eligibility).contains(introductoryJWS))
        #expect(!String(reflecting: authorization).contains(promotionalJWS))
        #expect(introductory.offer == .introductory(eligibility: eligibility))
        #expect(promotional.offer == .promotional(authorization: authorization))
    }

    @Test("购买优惠互斥且账单计划保留未知值")
    func purchaseOfferIsMutuallyExclusive() {
        let options = PurchaseOptions(
            billingPlan: .monthlyCommitment,
            offer: .winBack(offerID: "return-free-month")
        )

        #expect(options.billingPlan == .monthlyCommitment)
        #expect(options.offer == .winBack(offerID: "return-free-month"))
        #expect(PaymentBillingPlan.unknown("future-plan") == .unknown("future-plan"))
    }

    @Test("订阅定价条款完整保存账单价格、承诺和优惠")
    func subscriptionPricingTermsPreserveCommitmentAndOffers() {
        let freeTrial = PaymentSubscriptionOffer(
            id: nil,
            type: .introductory,
            price: 0,
            displayPrice: "$0.00",
            period: .init(unit: .week, value: 1),
            periodCount: 1,
            paymentMode: .freeTrial
        )
        let commitment = PaymentSubscriptionCommitment(
            price: 180,
            displayPrice: "¥180.00",
            period: .init(unit: .year, value: 1)
        )
        let terms = PaymentSubscriptionPricingTerms(
            billingPlan: .monthlyCommitment,
            billingPrice: 15,
            billingDisplayPrice: "¥15.00",
            billingPeriod: .init(unit: .month, value: 1),
            commitment: commitment,
            offers: [freeTrial]
        )

        #expect(terms.billingPlan == .monthlyCommitment)
        #expect(terms.billingPrice == 15)
        #expect(terms.billingDisplayPrice == "¥15.00")
        #expect(terms.billingPeriod == .init(unit: .month, value: 1))
        #expect(terms.commitment == commitment)
        #expect(terms.offers == [freeTrial])
    }

    @Test("商品优惠类型映射已知值并保留未来原始值")
    func productOfferTypesPreserveUnknownRawValue() {
        #expect(
            StoreKitPaymentStoreGateway.mapProductOfferType(
                StoreKit.Product.SubscriptionOffer.OfferType.introductory
            ) == .introductory
        )
        #expect(
            StoreKitPaymentStoreGateway.mapProductOfferType(
                StoreKit.Product.SubscriptionOffer.OfferType.promotional
            ) == .promotional
        )

        let future = StoreKit.Product.SubscriptionOffer.OfferType(
            rawValue: "FUTURE_OFFER"
        )
        #expect(
            StoreKitPaymentStoreGateway.mapProductOfferType(future) == .unknown(Int.min)
        )

        let unknownOffer = PaymentSubscriptionOffer(
            id: "future",
            type: .unknown(Int.min),
            typeRawValue: future.rawValue,
            price: 1,
            displayPrice: "$1.00",
            period: .init(unit: .month, value: 1),
            periodCount: 1,
            paymentMode: .unknown("FUTURE_MODE")
        )
        #expect(unknownOffer.typeRawValue == "FUTURE_OFFER")
    }

    @Test("外部购买意图使用商品和优惠组成稳定标识")
    func purchaseIntentIdentityIncludesOffer() {
        let offer = PaymentSubscriptionOffer(
            id: "return-free-month",
            type: .winBack,
            price: 0,
            displayPrice: "$0.00",
            period: .init(unit: .month, value: 1),
            periodCount: 1,
            paymentMode: .freeTrial
        )
        let standard = PaymentPurchaseIntent(productID: "monthly")
        let winBack = PaymentPurchaseIntent(productID: "monthly", offer: offer)

        #expect(standard.id == "monthly|standard")
        #expect(winBack.id == "monthly|winBack|return-free-month")
        #expect(winBack.productID == "monthly")
        #expect(winBack.offer == offer)
    }

    @Test("StoreKit 系统消息保留已知和未来原因")
    func storeMessageReasonsAreNeutral() {
        let winBack = PaymentStoreMessage(reason: .winBack)
        let future = PaymentStoreMessage(reason: .unknown(999))

        #expect(winBack.reason == .winBack)
        #expect(future.reason == .unknown(999))
        #expect(winBack.id != future.id)
    }

    @Test("实际优惠完整映射付款方式、类型和旧系统周期")
    func appliedOfferMappingPreservesKnownAndUnknownValues() {
        let freeTrial = StoreKitPaymentStoreGateway.mapAppliedOffer(
            id: nil,
            typeRawValue: StoreKit.Transaction.OfferType.introductory.rawValue,
            paymentModeRawValue: StoreKit.Product.SubscriptionOffer.PaymentMode.freeTrial.rawValue,
            periodRawValue: "P7D"
        )
        let payAsYouGo = StoreKitPaymentStoreGateway.mapAppliedOffer(
            id: nil,
            typeRawValue: StoreKit.Transaction.OfferType.introductory.rawValue,
            paymentModeRawValue: StoreKit.Product.SubscriptionOffer.PaymentMode.payAsYouGo.rawValue,
            periodRawValue: "P1M"
        )
        let payUpFront = StoreKitPaymentStoreGateway.mapAppliedOffer(
            id: "code",
            typeRawValue: StoreKit.Transaction.OfferType.code.rawValue,
            paymentModeRawValue: StoreKit.Product.SubscriptionOffer.PaymentMode.payUpFront.rawValue,
            periodRawValue: "P1Y"
        )
        let promotional = StoreKitPaymentStoreGateway.mapAppliedOffer(
            id: "promotion",
            typeRawValue: StoreKit.Transaction.OfferType.promotional.rawValue,
            paymentModeRawValue: nil,
            periodRawValue: nil
        )
        let winBack = StoreKitPaymentStoreGateway.mapAppliedOffer(
            id: "win-back",
            typeRawValue: StoreKit.Transaction.OfferType.winBack.rawValue,
            paymentModeRawValue: nil,
            periodRawValue: nil
        )
        let unknown = StoreKitPaymentStoreGateway.mapAppliedOffer(
            id: "future",
            typeRawValue: 999,
            paymentModeRawValue: "FUTURE_MODE",
            periodRawValue: "P3Q"
        )
        let legacyUppercaseFreeTrial = StoreKitPaymentStoreGateway.mapAppliedOffer(
            id: nil,
            typeRawValue: StoreKit.Transaction.OfferType.introductory.rawValue,
            paymentModeRawValue: "FREE_TRIAL",
            periodRawValue: "P1W"
        )
        let legacyUppercasePayUpFront = StoreKitPaymentStoreGateway.mapAppliedOffer(
            id: nil,
            typeRawValue: StoreKit.Transaction.OfferType.introductory.rawValue,
            paymentModeRawValue: "PAY_UP_FRONT",
            periodRawValue: "P1Y"
        )

        #expect(freeTrial == PaymentAppliedOffer(
            id: nil,
            type: .introductory,
            paymentMode: .freeTrial,
            period: PaymentSubscriptionPeriod(unit: .day, value: 7),
            periodRawValue: "P7D"
        ))
        #expect(payAsYouGo?.type == .introductory)
        #expect(payAsYouGo?.paymentMode == .payAsYouGo)
        #expect(payAsYouGo?.period == PaymentSubscriptionPeriod(unit: .month, value: 1))
        #expect(payUpFront?.type == .offerCode)
        #expect(payUpFront?.paymentMode == .payUpFront)
        #expect(payUpFront?.period == PaymentSubscriptionPeriod(unit: .year, value: 1))
        #expect(promotional?.type == .promotional)
        #expect(winBack?.type == .winBack)
        #expect(unknown?.type == .unknown(999))
        #expect(unknown?.paymentMode == .unknown("FUTURE_MODE"))
        #expect(unknown?.period == nil)
        #expect(unknown?.periodRawValue == "P3Q")
        #expect(legacyUppercaseFreeTrial?.paymentMode == .freeTrial)
        #expect(legacyUppercasePayUpFront?.paymentMode == .payUpFront)
    }

    @Test("StoreKit 有限序列悬挂时在超时后取消读取")
    func storeKitFiniteSequenceTimesOut() async {
        let termination = StreamTerminationRecorder()
        let hanging = AsyncStream<Int> { continuation in
            continuation.onTermination = { reason in
                Task { await termination.record(reason) }
            }
        }

        let result = await StoreKitPaymentStoreGateway.collectFiniteStream(
            hanging,
            timeoutNanoseconds: 30_000_000
        )

        #expect(result == nil)
        for _ in 0..<20 where !(await termination.wasCancelled) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await termination.wasCancelled)
    }
}

private actor StreamTerminationRecorder {
    private(set) var wasCancelled = false

    func record(_ reason: AsyncStream<Int>.Continuation.Termination) {
        if case .cancelled = reason {
            wasCancelled = true
        }
    }
}

@Suite("支付日志")
struct PaymentLoggingTests {
    @Test("关闭的日志处理器可安全忽略日志")
    func disabledLogger() {
        let entry = PaymentLogEntry(
            level: .info,
            category: "lifecycle",
            message: "started",
            metadata: ["productCount": "2"]
        )

        DisabledPaymentLogHandler().log(entry)
    }

    @Test("退款结果区分已提交和用户取消")
    func refundOutcomes() {
        #expect(PaymentRefundOutcome.submitted != .cancelled)
    }
}
