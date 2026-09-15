import Foundation

struct Forum: Identifiable, Equatable, Hashable, Codable, Sendable {
    var id: Int64
    var name: String
    var displayName: String
    var avatarURL: URL?
    var memberCount: Int
    var threadCount: Int
}

extension Forum {
    /// A forum shell built from a thread row, so the thread toolbar can show
    /// the forum's name and avatar from the first frame instead of swapping it
    /// in once the page loads. The counts are unknown at that point and stay
    /// zero; nothing the toolbar does reads them.
    ///
    /// The name is used exactly as the row carries it. `ForumMapper` builds the
    /// loaded forum's `displayName` from the server's raw name, so dressing the
    /// fallback up (appending 吧, for instance) would make the chip read one
    /// thing until the page landed and then flip to another — the same late
    /// change this fallback exists to remove.
    static func toolbarFallback(thread: ThreadSummary) -> Forum? {
        guard let name = thread.forumName, name.isEmpty == false else { return nil }
        return Forum(
            id: thread.forumID ?? 0,
            name: name,
            displayName: name,
            avatarURL: thread.forumAvatarURL,
            memberCount: 0,
            threadCount: 0
        )
    }
}
