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
        Self.latestSortOptions.contains(self)
    }

    /// Server `sort_type` values for `/c/f/frs/page`.
    ///
    /// `replyTime` must stay on 6 rather than 0: on a forum with a hot
    /// partition 0 already means hot ordering, which would make the 最新 and
    /// 热门 tabs render the same page. 6 is the explicit reply-time value and
    /// keeps its meaning on every forum, with or without a hot partition.
    /// `hot` falls back to reply-time ordering on forums that have no hot
    /// partition, which is what the server does for the official client too.
    var sortType: Int {
        switch self {
        case .replyTime:
            return 6
        case .publishTime:
            return 1
        case .hot:
            return 3
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
            return "查看本吧热门帖子"
        case .featured:
            return "仅显示精华帖"
        }
    }

    func metadata(for thread: ThreadSummary) -> ForumThreadMetadataPresentation {
        switch self {
        case .replyTime, .featured:
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
            // A hot listing has no per-thread heat value in the forum page
            // response, so it keeps showing when the thread last moved.
            return ForumThreadMetadataPresentation(
                date: thread.lastReplyAt ?? thread.createdAt,
                actionSuffix: "回复",
                systemImage: "flame"
            )
        }
    }
}

struct ForumThreadSortPreferenceStore {
    static let storageKey = "dev.infinityf4p.tiebapure.forum-thread-sort"
    static let selectionStorageKey = "dev.infinityf4p.tiebapure.forum-thread-selection"

    private let defaults: UserDefaults
    private let key: String
    private let selectionKey: String

    init(
        defaults: UserDefaults = .standard,
        key: String = ForumThreadSortPreferenceStore.storageKey,
        selectionKey: String = ForumThreadSortPreferenceStore.selectionStorageKey
    ) {
        self.defaults = defaults
        self.key = key
        self.selectionKey = selectionKey
    }

    /// The 最新 sub-sort remembered for this forum.
    func selection(for forum: Forum) -> ForumThreadCategory {
        var preferences = loadPreferences(from: key)
        let forumKey = Self.preferenceKey(for: forum)
        guard let rawValue = preferences[forumKey] else {
            return .replyTime
        }
        guard let category = ForumThreadCategory(rawValue: rawValue),
              category.belongsToLatestTab else {
            preferences.removeValue(forKey: forumKey)
            persist(preferences, to: key)
            return .replyTime
        }
        return category
    }

    /// The tab the user last had open in this forum. Unlike `selection(for:)`
    /// this remembers 热门 and 精华 as well, so coming back to a forum lands on
    /// the tab the user left instead of always resetting to 最新.
    func selectedCategory(for forum: Forum) -> ForumThreadCategory {
        var preferences = loadPreferences(from: selectionKey)
        let forumKey = Self.preferenceKey(for: forum)
        guard let rawValue = preferences[forumKey] else {
            return selection(for: forum)
        }
        guard let category = ForumThreadCategory(rawValue: rawValue) else {
            preferences.removeValue(forKey: forumKey)
            persist(preferences, to: selectionKey)
            return selection(for: forum)
        }
        return category
    }

    func select(_ category: ForumThreadCategory, for forum: Forum) {
        guard category.belongsToLatestTab else { return }

        var preferences = loadPreferences(from: key)
        let forumKey = Self.preferenceKey(for: forum)
        if category == .replyTime {
            preferences.removeValue(forKey: forumKey)
        } else {
            preferences[forumKey] = category.rawValue
        }
        persist(preferences, to: key)
        remember(category, for: forum)
    }

    /// Records which tab is open. 最新 is the default, so it is stored as an
    /// absent entry rather than as a value.
    func remember(_ category: ForumThreadCategory, for forum: Forum) {
        var preferences = loadPreferences(from: selectionKey)
        let forumKey = Self.preferenceKey(for: forum)
        if category == .replyTime {
            preferences.removeValue(forKey: forumKey)
        } else {
            preferences[forumKey] = category.rawValue
        }
        persist(preferences, to: selectionKey)
    }

    func reset() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: selectionKey)
    }

    static func preferenceKey(for forum: Forum) -> String {
        let sourceName = forum.name.isEmpty ? forum.displayName : forum.name
        let normalizedName = TiebaForumName.normalized(sourceName)
        if normalizedName.isEmpty == false {
            return "name:\(normalizedName)"
        }
        return "id:\(forum.id)"
    }

    private func loadPreferences(from key: String) -> [String: String] {
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
            persist(preferences, to: key)
        }
        return preferences
    }

    private func persist(_ preferences: [String: String], to key: String) {
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
