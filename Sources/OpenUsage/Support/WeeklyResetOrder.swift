import Foundation

enum WeeklyResetOrder {
    static func sorted<Element>(
        _ elements: [Element], snapshots: [String: ProviderSnapshot], now: Date = Date(),
        providerID: (Element) -> String
    ) -> [Element] {
        let ranked = elements.enumerated().map { index, element in
            (index: index, element: element,
             reset: nextReset(in: snapshots[providerID(element)], now: now) ?? .distantFuture)
        }
        return ranked.sorted {
            if $0.reset != $1.reset { return $0.reset < $1.reset }
            return $0.index < $1.index
        }.map(\.element)
    }

    private static func nextReset(in snapshot: ProviderSnapshot?, now: Date) -> Date? {
        guard let snapshot else { return nil }
        let weekly = snapshot.lines.compactMap { line -> (label: String, reset: Date?)? in
            guard case .progress(let label, _, _, _, let reset, let period, _) = line,
                  period == MetricPeriod.weekMs else { return nil }
            return (label, reset)
        }
        // Prefer the account-wide quota over separate model pools such as Sonnet and Spark.
        let main = weekly.filter { ["Weekly", "Weekly limit", "Weekly quota"].contains($0.label) }
        let candidates = main.isEmpty ? weekly : main
        return candidates.compactMap(\.reset).filter { $0 > now }.min()
    }
}
