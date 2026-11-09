import ActivityKit
import Foundation

struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var playing: Bool
        var position: Double
        var duration: Double
        var rate: Double
        var date: Date
        var accent: String
        var interval: ClosedRange<Date> {
            let speed = max(0.5, rate)
            let start = date.addingTimeInterval(-position / speed)
            return start...start.addingTimeInterval(max(1, duration / speed))
        }
    }
}
