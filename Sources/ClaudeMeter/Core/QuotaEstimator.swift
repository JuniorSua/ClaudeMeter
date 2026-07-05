import Foundation

/// Computes quota fullness with three levels of correctness:
/// detected (from logs), calibrated (manual budgets), or unavailable.
/// It never invents a percentage.
enum QuotaEstimator {
    static func quota(
        currentWindowTokens: Int,
        todayTokens: Int,
        weekTokens: Int,
        settings: AppSettings,
        resetAt: Date?,
        resetSource: ResetSource
    ) -> QuotaSnapshot {
        let percentage: Double?
        let quotaSource: QuotaSource
        let confidence: Confidence

        if let budget = settings.shortWindowTokenBudget, budget > 0 {
            percentage = Double(currentWindowTokens) / Double(budget) * 100
            quotaSource = .manualCalibration
            confidence = .medium
        } else if let budget = settings.dailyTokenBudget, budget > 0 {
            percentage = Double(todayTokens) / Double(budget) * 100
            quotaSource = .manualCalibration
            confidence = .medium
        } else if let budget = settings.weeklyTokenBudget, budget > 0 {
            percentage = Double(weekTokens) / Double(budget) * 100
            quotaSource = .manualCalibration
            confidence = .medium
        } else {
            percentage = nil
            quotaSource = .unavailable
            confidence = .unavailable
        }

        return QuotaSnapshot(
            percentageUsed: percentage,
            resetAt: resetAt,
            resetSource: resetSource,
            quotaSource: quotaSource,
            confidence: percentage == nil ? .unavailable : confidence
        )
    }
}
