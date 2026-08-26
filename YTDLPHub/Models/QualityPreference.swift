import Foundation

/// What the user asked for. The resolver returns every stream YouTube offers;
/// `StreamSelector` turns one of these preferences into a concrete plan.
enum QualityPreference: String, Codable, CaseIterable, Identifiable {
    case best
    case uhd2160
    case qhd1440
    case fhd1080
    case hd720
    case sd480
    case audioOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .best: return "Best available"
        case .uhd2160: return "Up to 2160p (4K)"
        case .qhd1440: return "Up to 1440p"
        case .fhd1080: return "Up to 1080p"
        case .hd720: return "Up to 720p"
        case .sd480: return "Up to 480p"
        case .audioOnly: return "Audio only (M4A)"
        }
    }

    var shortName: String {
        switch self {
        case .best: return "Best"
        case .uhd2160: return "2160p"
        case .qhd1440: return "1440p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        case .sd480: return "480p"
        case .audioOnly: return "Audio"
        }
    }

    var symbolName: String {
        self == .audioOnly ? "music.note" : "film"
    }

    var isAudioOnly: Bool { self == .audioOnly }

    /// Height cap, or `nil` for "whatever is best".
    var maxHeight: Int? {
        switch self {
        case .uhd2160: return 2160
        case .qhd1440: return 1440
        case .fhd1080: return 1080
        case .hd720: return 720
        case .sd480: return 480
        case .best, .audioOnly: return nil
        }
    }
}
