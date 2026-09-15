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
    static func toolbarFallback(thread: ThreadSummary) -> Forum? {
        guard let name = thread.forumName, name.isEmpty == false else { return nil }
        return Forum(
            id: thread.forumID ?? 0,
            name: name,
            displayName: name.hasSuffix("吧") ? name : "\(name)吧",
            avatarURL: thread.forumAvatarURL,
            memberCount: 0,
            threadCount: 0
        )
    }
}
