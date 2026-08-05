/// Stable round-robin batching for model collections whose membership can
/// change between ticks.
///
/// The path anchor preserves position across insertions before the cursor. The
/// numeric fallback preserves position when the anchored item is temporarily
/// absent (for example, while its repository is handled by another polling
/// gate) instead of restarting every scan at the first sidebar entry.
struct RoundRobinBatchCursor {
    private var nextPath: String?
    private var fallbackIndex = 0

    mutating func nextBatch<Element>(
        from elements: [Element],
        maximumCount: Int,
        path: (Element) -> String
    ) -> [Element] {
        precondition(maximumCount > 0)
        guard !elements.isEmpty else {
            reset()
            return []
        }

        let anchoredIndex = nextPath.flatMap { nextPath in
            elements.firstIndex { path($0) == nextPath }
        }
        let startIndex = anchoredIndex
            ?? min(fallbackIndex, elements.count - 1)
        let batchCount = min(maximumCount, elements.count)
        let batch = (0..<batchCount).map {
            elements[(startIndex + $0) % elements.count]
        }

        if batchCount < elements.count {
            let nextIndex = (startIndex + batchCount) % elements.count
            nextPath = path(elements[nextIndex])
            fallbackIndex = nextIndex
        } else {
            reset()
        }
        return batch
    }

    private mutating func reset() {
        nextPath = nil
        fallbackIndex = 0
    }
}
