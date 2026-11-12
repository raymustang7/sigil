import Foundation

/// Splits the hint budget across visible windows so that no window is starved by the ones in
/// front of it.
///
/// Rule: **equal share, leftovers passed on.** Every window that still needs hints gets the same
/// share of what remains; a window that needs less than its share takes only what it needs and
/// the surplus is re-shared among the windows still short. The loop ends when the budget is
/// spent or every window is satisfied. Simulated against recorded scans, this is the only rule
/// under which a window with few elements is never trimmed while a larger one keeps a surplus.
enum HintBudget {
    /// - Parameters:
    ///   - demands: number of candidate elements per window, in scan order.
    ///   - budget: total hints available to these windows.
    /// - Returns: hints granted per window, parallel to `demands`; never above the demand, and
    ///   summing to at most `budget`.
    static func allocate(demands: [Int], budget: Int) -> [Int] {
        var granted = Array(repeating: 0, count: demands.count)
        var remaining = max(0, budget)
        var short = demands.indices.filter { demands[$0] > 0 }

        while remaining > 0, !short.isEmpty {
            let share = remaining / short.count
            if share == 0 {
                // Fewer units than windows: one each to the earliest windows, then stop.
                for index in short.prefix(remaining) { granted[index] += 1 }
                break
            }
            for index in short {
                let take = min(share, demands[index] - granted[index])
                granted[index] += take
                remaining -= take
            }
            short.removeAll { granted[$0] >= demands[$0] }
        }
        return granted
    }
}
