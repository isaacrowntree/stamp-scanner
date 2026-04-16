import Foundation

/// Smart-folder style filters for the sidebar.
enum SmartFolder: String, Identifiable, CaseIterable, Hashable {
    case all, recent, unidentified, flagged, partials, obscured, duplicates

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:          return "All"
        case .recent:       return "Recent"
        case .unidentified: return "Unidentified"
        case .flagged:      return "Flagged"
        case .partials:     return "Partials"
        case .obscured:     return "Obscured"
        case .duplicates:   return "Duplicates"
        }
    }
    var systemImage: String {
        switch self {
        case .all:          return "square.grid.2x2"
        case .recent:       return "clock"
        case .unidentified: return "questionmark.circle"
        case .flagged:      return "flag"
        case .partials:     return "scissors"
        case .obscured:     return "eye.slash"
        case .duplicates:   return "rectangle.on.rectangle"
        }
    }
}

enum SortOrder: String, CaseIterable, Hashable {
    case newestFirst, oldestFirst, highestConfidence, lowestConfidence
    var label: String {
        switch self {
        case .newestFirst:       return "Newest first"
        case .oldestFirst:       return "Oldest first"
        case .highestConfidence: return "Highest confidence"
        case .lowestConfidence:  return "Lowest confidence"
        }
    }
}

struct LibraryFilter: Equatable {
    var folder: SmartFolder = .all
    var search: String = ""
    var sort: SortOrder = .newestFirst
}
