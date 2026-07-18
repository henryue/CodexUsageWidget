import Foundation

public enum ResetTimeFormatter {
    public static func compactRemaining(from now: Date, to reset: Date?) -> String {
        guard let reset else { return "Unavailable" }
        let totalMinutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public static func updatedLabel(fetchedAt: Date, now: Date, stale: Bool) -> String {
        let elapsedMinutes = max(0, Int(now.timeIntervalSince(fetchedAt) / 60))
        if stale {
            if elapsedMinutes < 60 { return "Stale · \(elapsedMinutes)m ago" }
            let hours = elapsedMinutes / 60
            return "Stale · \(hours)h ago"
        }
        if elapsedMinutes < 1 { return "Updated now" }
        return "Updated \(elapsedMinutes)m ago"
    }
}
