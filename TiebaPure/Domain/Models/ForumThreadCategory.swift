import Foundation

enum ForumThreadCategory: String, CaseIterable, Identifiable, Sendable {
    case replyTime
    case publishTime
    case hot
    case featured

    var id: Self { self }

    static let latestSortOptions: [Self] = [.replyTime, .publishTime]

    var topLevelTitle: String {
        switch self {
        case .replyTime, .publishTime:
            return "最新"
        case .hot:
            return "热门"
        case .featured:
            return "精华"
        }
    }

    var sortOptionTitle: String {
        switch self {
        case .replyTime:
            return "回复时间排序"
        case .publishTime:
            return "发帖时间排序"
        case .hot:
            return "热门"
        case .featured:
            return "精华"
        }
    }

    var belongsToLatestTab: Bool {
        switch self {
        case .replyTime, .publishTime:
            return true
        case .hot, .featured:
            return false
        }
    }

    var sortType: Int {
        switch self {
        case .replyTime:
            return 0
        case .publishTime:
            return 1
        case .hot:
            return 2
        case .featured:
            return -1
        }
    }

    var goodClassifyID: Int? {
        self == .featured ? 0 : nil
    }

    var accessibilityIdentifier: String {
        switch self {
        case .replyTime:
            return "forum-sort-reply-time"
        case .publishTime:
            return "forum-sort-publish-time"
        case .hot:
            return "forum-category-hot"
        case .featured:
            return "forum-category-featured"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .replyTime:
            return "按最近回复时间排序"
        case .publishTime:
            return "按发帖时间排序"
        case .hot:
            return "按热度排序"
        case .featured:
            return "仅显示精华帖"
        }
    }

    func metadata(for thread: ThreadSummary) -> ForumThreadMetadataPresentation {
        switch self {
        case .replyTime:
            return ForumThreadMetadataPresentation(
                date: thread.lastReplyAt ?? thread.createdAt,
                actionSuffix: "回复",
                systemImage: "bubble.left.and.text.bubble.right"
            )
        case .publishTime:
            return ForumThreadMetadataPresentation(
                date: thread.createdAt ?? thread.lastReplyAt,
                actionSuffix: "发布",
                systemImage: "clock"
            )
        case .hot:
            return ForumThreadMetadataPresentation(
                date: thread.lastReplyAt ?? thread.createdAt,
                actionSuffix: "回复",
                systemImage: "flame.fill"
            )
        case .featured:
            return ForumThreadMetadataPresentation(
                date: thread.lastReplyAt ?? thread.createdAt,
                actionSuffix: "回复",
                systemImage: "bubble.left.and.text.bubble.right"
            )
        }
    }
}

struct ForumThreadSortPreferenceStore {
    static let storageKey = "dev.infinityf4p.tiebapure.forum-thread-sort"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = ForumThreadSortPreferenceStore.storageKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func selection(for forum: Forum) -> ForumThreadCategory {
        var preferences = loadPreferences()
        let forumKey = Self.preferenceKey(for: forum)
        guard let rawValue = preferences[forumKey] else {
            return .replyTime
        }
        guard let category = ForumThreadCategory(rawValue: rawValue) else {
            preferences.removeValue(forKey: forumKey)
            persist(preferences)
            return .replyTime
        }
        return category
    }

    func select(_ category: ForumThreadCategory, for forum: Forum) {
        var preferences = loadPreferences()
        let forumKey = Self.preferenceKey(for: forum)
        // "最新" (replyTime) is the implicit default. Both the bare latest
        // tab and the unsupported fallback clear the entry so the default
        // value can be inferred from a missing key.
        if category == .replyTime {
            preferences.removeValue(forKey: forumKey)
        } else {
            preferences[forumKey] = category.rawValue
        }
        persist(preferences)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }

    static func preferenceKey(for forum: Forum) -> String {
        let sourceName = forum.name.isEmpty ? forum.displayName : forum.name
        let normalizedName = TiebaForumName.normalized(sourceName)
        if normalizedName.isEmpty == false {
            return "name:\(normalizedName)"
        }
        return "id:\(forum.id)"
    }

    private func loadPreferences() -> [String: String] {
        guard let stored = defaults.dictionary(forKey: key) else {
            if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
            }
            return [:]
        }

        var preferences: [String: String] = [:]
        var needsRepair = false
        for (forumKey, value) in stored {
            guard let rawValue = value as? String else {
                needsRepair = true
                continue
            }
            preferences[forumKey] = rawValue
        }
        if needsRepair {
            persist(preferences)
        }
        return preferences
    }

    private func persist(_ preferences: [String: String]) {
        if preferences.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(preferences, forKey: key)
        }
    }
}

struct ForumThreadMetadataPresentation: Equatable, Sendable {
    let date: Date?
    let actionSuffix: String
    let systemImage: String
}
