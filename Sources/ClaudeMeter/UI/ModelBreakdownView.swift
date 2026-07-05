import SwiftUI

struct ModelBreakdownView: View {
    let breakdown: [ModelUsage]

    private var total: Int {
        max(1, breakdown.reduce(0) { $0 + $1.totalTokens })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(breakdown) { usage in
                let fraction = Double(usage.totalTokens) / Double(total)
                HStack {
                    Text(usage.model)
                        .font(.system(size: 12))
                    Spacer()
                    Text(HumanFormatters.tokens(usage.totalTokens))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(HumanFormatters.percent(fraction * 100))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
        }
    }
}
