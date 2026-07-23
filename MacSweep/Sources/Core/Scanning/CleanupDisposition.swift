/// UI-independent confirmation copy and symbol metadata for cleanup actions.
///
/// The SwiftUI layer owns presentation details such as tint colors, while this
/// contract keeps every user-facing action description reachable by SwiftPM
/// tests alongside the cleanup review summary.
enum CleanupDisposition: Sendable {
    case trash
    case permanent
    case localCloudCopy
    case mixed
    case toolNative(String)

    var title: String {
        switch self {
        case .trash: return "Move to Trash"
        case .permanent: return "Delete Permanently"
        case .localCloudCopy: return "Remove Local Copies"
        case .mixed: return "Run Cleanup"
        case .toolNative: return "Run Tool Cleanup"
        }
    }

    var detail: String {
        switch self {
        case .trash:
            return "Selected files move to Trash and can be restored until Trash is emptied."
        case .permanent:
            return "Selected files are deleted permanently and cannot be restored from Trash."
        case .localCloudCopy:
            return "Downloaded local copies are evicted; the cloud originals remain available. "
                + "Provider caches may be deleted permanently."
        case .mixed:
            return "Each module uses its declared action. Some items move to Trash; "
                + "tool-managed caches or Trash contents may be removed permanently."
        case .toolNative(let detail):
            return detail
        }
    }

    var icon: String {
        switch self {
        case .trash: return "trash"
        case .permanent: return "trash.slash"
        case .localCloudCopy: return "icloud.and.arrow.up"
        case .mixed: return "checkmark.shield"
        case .toolNative: return "terminal"
        }
    }
}
