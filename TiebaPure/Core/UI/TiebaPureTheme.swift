import SwiftUI
import UIKit

/// One light tap the moment a like is toggled, mirroring Coolapk's tap
/// feedback regardless of how the network write eventually lands.
enum LikeHaptics {
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    static func triggerToggled() {
        generator.impactOccurred(intensity: 0.8)
    }
}

enum TiebaPureTheme {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    enum Radius {
        static let chip: CGFloat = 6
        static let media: CGFloat = 8
        static let card: CGFloat = 8
    }

    enum AvatarSize {
        static let small: CGFloat = 32
        static let medium: CGFloat = 40
        static let large: CGFloat = 48
    }

    enum IconSize {
        static let inline: CGFloat = 17
        static let toolbar: CGFloat = 22
        static let play: CGFloat = 48
    }

    enum ReadableWidth {
        static let maxPhone: CGFloat = .infinity
        static let maxTablet: CGFloat = 680
    }

    /// Metrics for the Liquid Glass controls the system draws in a navigation
    /// bar. A custom toolbar control has to match them or it reads as a
    /// different, cheaper material sitting in the same row.
    enum ToolbarGlass {
        /// Measured from an iOS 26 device screenshot: the system back button
        /// and the trailing button group are both 132px tall, which is 45pt on
        /// that device. The app's own forum chip was 34pt — 11pt short — so
        /// its capsule radius (half the height) was wrong too.
        ///
        /// Earlier systems use the compact bar control instead.
        static var controlHeight: CGFloat {
            if #available(iOS 26.0, *) {
                return 45
            }
            return 34
        }
    }

    enum ColorToken {
        static let primaryAccent = Color(uiColor: .systemBlue)
        static let videoAccent = Color(red: 0.96, green: 0.62, blue: 0.04)
        static let readerGroupedBackground = Color(uiColor: .systemGroupedBackground)
        static let readerSectionBand = Color(uiColor: .secondarySystemBackground)
        static let readerSecondarySurface = Color(uiColor: .secondarySystemGroupedBackground)
        static let readerTertiarySurface = Color(uiColor: .tertiarySystemGroupedBackground)
        static let readerSeparator = Color(uiColor: .separator)
    }
}

extension View {
    func readableWidth(alignment: Alignment = .center) -> some View {
        frame(maxWidth: TiebaPureTheme.ReadableWidth.maxTablet, alignment: alignment)
    }

    func minTouchTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
    }

    /// iOS 26 blends scrolling content into the Liquid Glass toolbars with a
    /// scroll edge effect. The default style draws a hard seam right below the
    /// navigation bar and above the floating tab bar; reading surfaces look
    /// better with the soft variant Apple documents alongside it.
    ///
    /// Apple warns that soft edges separate content less strongly than the
    /// default, so anything pinned to an edge (fixed table headers, text that
    /// sits outside the Liquid Glass controls) still has to stay legible in
    /// every scroll position. On iOS 16.4 – 25 there is no edge effect at all
    /// and this is a no-op.
    @ViewBuilder
    func softScrollEdgeEffect(for edges: Edge.Set = .all) -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}

enum PaginationPrefetchPolicy {
    static func shouldLoadMore(currentIndex: Int, totalCount: Int, threshold: Int = 5) -> Bool {
        guard totalCount > 0, currentIndex >= 0, currentIndex < totalCount else { return false }
        return currentIndex >= max(totalCount - max(threshold, 1), 0)
    }
}

struct LocallyFilteredPaginationDecision: Equatable {
    let consecutiveHiddenPageCount: Int
    let shouldAutomaticallyLoadNextPage: Bool
    let shouldOfferManualContinuation: Bool
}

/// Prevents a server feed from stalling when a complete page is removed by
/// local block rules. One user-triggered load may skip a bounded number of
/// hidden pages; the caller then exposes a manual continuation control.
enum LocallyFilteredPaginationPolicy {
    static let automaticPageLimit = 5

    static func decision(
        visibleItemCount: Int,
        serverHasMore: Bool,
        consecutiveHiddenPageCount: Int,
        automaticPageLimit: Int = LocallyFilteredPaginationPolicy.automaticPageLimit
    ) -> LocallyFilteredPaginationDecision {
        guard visibleItemCount <= 0, serverHasMore else {
            return LocallyFilteredPaginationDecision(
                consecutiveHiddenPageCount: 0,
                shouldAutomaticallyLoadNextPage: false,
                shouldOfferManualContinuation: false
            )
        }

        let nextHiddenCount = max(consecutiveHiddenPageCount, 0) + 1
        let resolvedLimit = max(automaticPageLimit, 1)
        return LocallyFilteredPaginationDecision(
            consecutiveHiddenPageCount: nextHiddenCount,
            shouldAutomaticallyLoadNextPage: nextHiddenCount < resolvedLimit,
            shouldOfferManualContinuation: nextHiddenCount >= resolvedLimit
        )
    }
}
