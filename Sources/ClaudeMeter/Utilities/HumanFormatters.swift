import Foundation

enum HumanFormatters {
    /// 999 → "999", 1234 → "1.2k", 18420 → "18k", 1_400_000 → "1.4M"
    static func tokens(_ n: Int) -> String {
        let value = abs(n)
        let sign = n < 0 ? "-" : ""
        if value < 1000 {
            return "\(sign)\(value)"
        }
        if value < 1_000_000 {
            let k = Double(value) / 1000.0
            if k >= 999.5 { return "\(sign)1M" }
            if k < 10 {
                let s = String(format: "%.1f", k)
                return "\(sign)\(s.hasSuffix(".0") ? String(s.dropLast(2)) : s)k"
            }
            return "\(sign)\(Int(k.rounded()))k"
        }
        let m = Double(value) / 1_000_000.0
        let s = String(format: "%.1f", m)
        return "\(sign)\(s.hasSuffix(".0") ? String(s.dropLast(2)) : s)M"
    }

    /// Full number with thousands separators, e.g. 18420 → "18,420"
    static func tokensExact(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "$0.01", "~$0.42" when estimated.
    static func cost(_ value: Decimal, estimated: Bool) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.currencySymbol = "$"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let s = f.string(from: value as NSDecimalNumber) ?? "$\(value)"
        return estimated ? "~\(s)" : s
    }

    /// 840s → "14m", 8040s → "2h 14m", 97200s → "1d 3h"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let minutes = (total / 60) % 60
        let hours = (total / 3600) % 24
        let days = total / 86400
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(minutes, total > 0 ? 1 : 0))m"
    }

    /// 42.3 → "42%"
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}
