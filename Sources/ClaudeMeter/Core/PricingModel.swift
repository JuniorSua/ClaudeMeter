import Foundation

/// Per-million-token USD prices for one model family.
struct ModelPricing: Codable, Equatable {
    var inputPerMTok: Decimal
    var outputPerMTok: Decimal
    var cacheWritePerMTok: Decimal
    var cacheReadPerMTok: Decimal
}

/// Editable pricing table. Model names are matched by family substring
/// (fable / opus / sonnet / haiku); anything else is "unknown" and only
/// priced when fallback pricing is enabled.
struct PricingTable: Codable, Equatable {
    var fable: ModelPricing
    var opus: ModelPricing
    var sonnet: ModelPricing
    var haiku: ModelPricing
    var fallback: ModelPricing

    static let `default` = PricingTable(
        fable: ModelPricing(inputPerMTok: 10, outputPerMTok: 50, cacheWritePerMTok: 12.5, cacheReadPerMTok: 1),
        opus: ModelPricing(inputPerMTok: 5, outputPerMTok: 25, cacheWritePerMTok: 6.25, cacheReadPerMTok: 0.5),
        sonnet: ModelPricing(inputPerMTok: 3, outputPerMTok: 15, cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.3),
        haiku: ModelPricing(inputPerMTok: 1, outputPerMTok: 5, cacheWritePerMTok: 1.25, cacheReadPerMTok: 0.1),
        fallback: ModelPricing(inputPerMTok: 3, outputPerMTok: 15, cacheWritePerMTok: 3.75, cacheReadPerMTok: 0.3)
    )

    init(fable: ModelPricing, opus: ModelPricing, sonnet: ModelPricing, haiku: ModelPricing, fallback: ModelPricing) {
        self.fable = fable
        self.opus = opus
        self.sonnet = sonnet
        self.haiku = haiku
        self.fallback = fallback
    }

    // Settings persisted before the fable row existed lack the key; fall
    // back to the default so decoding old settings JSON keeps working.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fable = try container.decodeIfPresent(ModelPricing.self, forKey: .fable) ?? Self.default.fable
        opus = try container.decode(ModelPricing.self, forKey: .opus)
        sonnet = try container.decode(ModelPricing.self, forKey: .sonnet)
        haiku = try container.decode(ModelPricing.self, forKey: .haiku)
        fallback = try container.decode(ModelPricing.self, forKey: .fallback)
    }

    enum Family: String {
        case fable, opus, sonnet, haiku, unknown
    }

    static func family(for model: String?) -> Family {
        guard let model = model?.lowercased() else { return .unknown }
        if model.contains("fable") || model.contains("mythos") { return .fable }
        if model.contains("opus") { return .opus }
        if model.contains("sonnet") { return .sonnet }
        if model.contains("haiku") { return .haiku }
        return .unknown
    }

    func pricing(for model: String?, allowFallback: Bool) -> ModelPricing? {
        switch Self.family(for: model) {
        case .fable: return fable
        case .opus: return opus
        case .sonnet: return sonnet
        case .haiku: return haiku
        case .unknown: return allowFallback ? fallback : nil
        }
    }

    /// Estimated cost in USD for the given token counts, or nil when the
    /// model is unknown and fallback pricing is disabled.
    func estimateCost(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        allowFallback: Bool
    ) -> Decimal? {
        guard let p = pricing(for: model, allowFallback: allowFallback) else { return nil }
        let mtok = Decimal(1_000_000)
        return (Decimal(inputTokens) * p.inputPerMTok
            + Decimal(outputTokens) * p.outputPerMTok
            + Decimal(cacheCreationTokens) * p.cacheWritePerMTok
            + Decimal(cacheReadTokens) * p.cacheReadPerMTok) / mtok
    }
}
