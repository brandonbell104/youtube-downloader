import Foundation

enum Formatters {
    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        return byteCount.string(fromByteCount: value)
    }

    static func speed(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return byteCount.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func duration(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func eta(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return duration(seconds: Double(seconds)) + " left"
    }
}
