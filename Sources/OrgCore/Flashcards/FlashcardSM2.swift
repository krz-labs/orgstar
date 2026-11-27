import Foundation

extension Flashcards {
    /// org-fc's variant of SM2 (`org-fc-algo-sm2`, `org-fc-algorithm` `sm2-v1`) with its
    /// default parameters.
    public struct SM2: Sendable, Equatable {
        public var easeMin = 1.3
        public var easeMax = 5.0
        public var easeInitial = 2.5
        public var fuzzMin = 0.9
        public var fuzzMax = 1.1
        public var changes: [Rating: Double] = [.again: -0.3, .hard: -0.15, .good: 0.0, .easy: 0.15]
        /// Intervals in days of the first boxes.
        public var intervals = [0.0, 0.01, 1.0, 6.0]

        public static let headers = ["position", "ease", "box", "interval", "due"]

        public init() {}

        /// `org-fc-algo-initial-review-data`.
        public func initial(_ name: String, now: Date) -> [String: String] {
            ["position": name, "ease": String(format: "%.2f", easeInitial), "box": "0", "interval": String(format: "%.2f", 0.0),
             "due": Flashcards.timestamp(now)]
        }

        /// `org-fc-algo-next-review-data`. `random` stands for `cl-random`'s value as a
        /// fraction of its limit, in [0, 1).
        public func next(_ current: [String: String], rating: Rating, now: Date, random: Double) -> [String: String] {
            let ease = Flashcards.number(current["ease"])
            let box = Int(Flashcards.number(current["box"]))
            let interval = Flashcards.number(current["interval"])
            let nextEase = box < 2 ? ease : min(max(ease + changes[rating]!, easeMin), easeMax)
            let nextBox = box == 0 && rating == .easy ? 2 : rating == .again ? 0 : box + 1
            let nextInterval: Double
            if nextBox < intervals.count {
                nextInterval = intervals[nextBox]
            } else {
                nextInterval = nextEase * interval * (fuzzMin + (fuzzMax - fuzzMin) * random)
            }
            return ["ease": String(format: "%.2f", nextEase), "box": String(nextBox), "interval": String(format: "%.2f", nextInterval),
                    "due": Flashcards.timestamp(now, plus: nextInterval)]
        }
    }
}
