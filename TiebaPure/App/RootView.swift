import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var account: Account?
    @State private var lastScenePhase: ScenePhase = .inactive
    @State private var didLoadAccount = false
    @State private var externalRoute: ExternalRoute?
    @State private var accountTransitionTask: Task<Void, Never>?
    @State private var accountTransitionGeneration = 0
    @State private var expiringSession: AccountSessionIdentity?
    @State private var sessionExpirationTask: Task<Void, Never>?
    @State private var sessionExpirationNotice: SessionExpirationNotice?

    var body: some View {
        Group {
            if didLoadAccount == false {
                ProgressView()
                    .controlSize(.large)
            } else {
                MainTabView(account: account)
            }
        }
        .task {
            let generation = accountTransitionGeneration
            let loadedAccount = try? await environment.accountStore.load()
            guard generation == accountTransitionGeneration else { return }
            await updateAccount(loadedAccount, generation: generation)
            guard generation == accountTransitionGeneration else { return }
            didLoadAccount = true
            await signAutomaticallyIfNeeded()
        }
        .onChange(of: scenePhase) { newPhase in
            let previousPhase = lastScenePhase
            lastScenePhase = newPhase
            // "First open of the day" also covers returning from the
            // background: the store's own per-day stamp keeps it to one run.
            guard previousPhase == .background, newPhase == .active else { return }
            Task { await signAutomaticallyIfNeeded() }
        }
        .onReceive(environment.accountStore.accountDidChange) { newAccount in
            accountTransitionGeneration &+= 1
            let generation = accountTransitionGeneration
            accountTransitionTask?.cancel()
            accountTransitionTask = Task { @MainActor in
                await updateAccount(newAccount, generation: generation)
                guard Task.isCancelled == false,
                      generation == accountTransitionGeneration else { return }
                didLoadAccount = true
                await signAutomaticallyIfNeeded()
            }
        }
        .onReceive(environment.sessionExpirationMonitor.expiredSessions) { session in
            handleSessionExpiration(session)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            InlineContentTextMeasurementCache.drain()
            InlineContentTextViewPool.drain()
            Task {
                await TiebaImagePipeline.shared.releaseDecodedImageCache()
            }
        }
        .onOpenURL { url in
            guard let route = ExternalRoute.parse(url) else { return }
            externalRoute = route
        }
        .fullScreenCover(item: $externalRoute) { route in
            ExternalRouteView(account: account, route: route) {
                externalRoute = nil
            }
        }
        .alert(item: $sessionExpirationNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private func signAutomaticallyIfNeeded() async {
        await environment.forumSignCoordinator.signAutomaticallyIfNeeded(account: account)
    }

    @MainActor
    private func handleSessionExpiration(_ session: AccountSessionIdentity) {
        guard SessionExpirationHandlingPolicy.shouldHandle(
            reportedSession: session,
            currentAccount: account,
            expiringSession: expiringSession
        ) else { return }

        expiringSession = session
        sessionExpirationNotice = .expired()
        sessionExpirationTask = Task { @MainActor in
            do {
                try await environment.logoutCoordinator.logOut()
            } catch is CancellationError {
                if account?.sessionIdentity == session {
                    expiringSession = nil
                }
            } catch {
                if account?.sessionIdentity == session {
                    expiringSession = nil
                    sessionExpirationNotice = .logoutFailed(
                        reason: ReaderErrorMessage.message(for: error)
                    )
                }
            }
            sessionExpirationTask = nil
        }
    }

    @MainActor
    private func updateAccount(_ newAccount: Account?, generation: Int) async {
        let previousAccount = account
        let invalidatedAccountID = AccountTransitionPolicy.invalidatedAccountID(
            previous: previousAccount,
            next: newAccount
        )
        let invalidatedSession = AccountTransitionPolicy.invalidatedSession(
            previous: previousAccount,
            next: newAccount
        )
        if let invalidatedSession {
            environment.socialMutationCoordinator.establishInvalidationBarrier(
                session: invalidatedSession
            )
            environment.forumSignCoordinator.establishInvalidationBarrier(
                session: invalidatedSession
            )
        }
        if let invalidatedAccountID {
            environment.contentSubmissionCoordinator.establishInvalidationBarrier(
                accountID: invalidatedAccountID
            )
        }
        var socialDrain: Task<Void, Never>?
        if let invalidatedSession {
            socialDrain = Task { @MainActor in
                await environment.socialMutationCoordinator.drainInvalidatedOperations(
                    session: invalidatedSession
                )
            }
        }
        var contentDrain: Task<Void, Never>?
        if let invalidatedAccountID {
            contentDrain = Task { @MainActor in
                await environment.contentSubmissionCoordinator.drainInvalidatedOperations(
                    accountID: invalidatedAccountID
                )
            }
        }
        var forumSignDrain: Task<Void, Never>?
        if let invalidatedSession {
            forumSignDrain = Task { @MainActor in
                await environment.forumSignCoordinator.drainInvalidatedOperations(
                    session: invalidatedSession
                )
            }
        }
        if let socialDrain {
            await socialDrain.value
        }
        if let contentDrain {
            await contentDrain.value
        }
        if let forumSignDrain {
            await forumSignDrain.value
        }
        defer {
            if let invalidatedAccountID {
                environment.contentSubmissionCoordinator.endInvalidation(
                    accountID: invalidatedAccountID
                )
            }
            if let invalidatedSession {
                environment.forumSignCoordinator.endInvalidation(
                    session: invalidatedSession
                )
                environment.socialMutationCoordinator.endInvalidation(
                    session: invalidatedSession
                )
            }
        }

        if let previousAccount, invalidatedSession != nil {
            environment.socialRelationshipState.reset(accountID: previousAccount.id)
        }
        guard Task.isCancelled == false,
              generation == accountTransitionGeneration else { return }
        account = newAccount
        if newAccount?.sessionIdentity != expiringSession {
            expiringSession = nil
        }
        if AccountTransitionPolicy.shouldReleaseGlobalInvalidation(
            previous: previousAccount,
            next: newAccount
        ) {
            // A successful logout deliberately leaves the global submission
            // barrier active. Release it only after the replacement account is
            // the session visible to the application.
            environment.contentSubmissionCoordinator.endInvalidation()
            environment.socialMutationCoordinator.endInvalidation()
            environment.forumSignCoordinator.endInvalidation()
        }
    }
}

private struct SessionExpirationNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static func expired() -> SessionExpirationNotice {
        SessionExpirationNotice(
            title: "登录已失效",
            message: "当前账号的登录状态已失效，应用将退出该账号，请重新登录。"
        )
    }

    static func logoutFailed(reason: String) -> SessionExpirationNotice {
        SessionExpirationNotice(
            title: "自动退出失败",
            message: "登录状态已失效，但未能清理本机账号数据。\(reason)"
        )
    }
}

enum AccountTransitionPolicy {
    static func invalidatedSession(
        previous: Account?,
        next: Account?
    ) -> AccountSessionIdentity? {
        guard let previous else { return nil }
        guard next?.sessionIdentity == previous.sessionIdentity else {
            return previous.sessionIdentity
        }
        return nil
    }

    static func invalidatedAccountID(previous: Account?, next: Account?) -> String? {
        invalidatedSession(previous: previous, next: next)?.accountID
    }

    static func shouldReleaseGlobalInvalidation(previous: Account?, next: Account?) -> Bool {
        previous == nil && next != nil
    }
}

/// Container for externally opened destinations. A cover with its own stack
/// keeps deep links independent of whichever tab and stack the user was in.
private struct ExternalRouteView: View {
    let account: Account?
    let route: ExternalRoute
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case let .thread(id, postID):
                    ThreadDetailView(account: account, threadID: id, initialPostID: postID)
                case let .forum(name):
                    ForumThreadsView(account: account, forum: Forum(
                        id: 0,
                        name: name,
                        displayName: name.hasSuffix("吧") ? name : "\(name)吧",
                        avatarURL: nil,
                        memberCount: 0,
                        threadCount: 0
                    ))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", action: onClose)
                        .accessibilityIdentifier("external-route-close")
                }
            }
        }
        .softScrollEdgeEffect()
    }
}

private struct MainTabView: View {
    let account: Account?
    @State private var selectedTab: RootTab = .home
    @State private var homeRefreshToken = 0

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        // One style for every tab: content now fades into the navigation bar
        // and the floating Liquid Glass tab bar instead of ending on a hard
        // seam.
        .softScrollEdgeEffect()
        .background(
            TabSelectionObserver {
                homeRefreshToken += 1
            }
        )
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: tabSelection) {
            Tab("首页", systemImage: "house", value: RootTab.home) {
                HomeView(account: account, refreshToken: homeRefreshToken)
            }

            Tab("进吧", systemImage: "square.grid.2x2", value: RootTab.forums) {
                ForumHubView(account: account)
            }

            Tab("我的", systemImage: "person.circle", value: RootTab.me) {
                MeView(account: account)
            }
        }
        // Feeds report their scroll direction to `TabBarControllerProxy`,
        // which shrinks the bar Instagram-style (a proportional scale-down,
        // not the system pill).
    }

    private var legacyTabView: some View {
        TabView(selection: tabSelection) {
            HomeView(account: account, refreshToken: homeRefreshToken)
                .tabItem {
                    Label("首页", systemImage: "house")
                }
                .tag(RootTab.home)

            ForumHubView(account: account)
                .tabItem {
                    Label("进吧", systemImage: "square.grid.2x2")
                }
                .tag(RootTab.forums)

            MeView(account: account)
                .tabItem {
                    Label("我的", systemImage: "person.circle")
                }
                .tag(RootTab.me)
        }
    }

    private var tabSelection: Binding<RootTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                selectedTab = newValue
            }
        )
    }
}

enum RootTab: Hashable {
    case home
    case forums
    case me
}

private struct TabSelectionObserver: UIViewControllerRepresentable {
    let onReselectHome: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReselectHome: onReselectHome)
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        context.coordinator.onReselectHome = onReselectHome
        controller.coordinator = context.coordinator
        controller.isObservationActive = true
        controller.attachToTabBarController()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Coordinator) {
        controller.isObservationActive = false
        coordinator.detach()
    }

    final class Controller: UIViewController {
        var coordinator: Coordinator
        var isObservationActive = true

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachToTabBarController()
        }

        func attachToTabBarController() {
            guard isObservationActive else { return }
            var visited = Set<ObjectIdentifier>()
            guard let tabBarController = tabBarController ?? findTabBarController(
                from: view.window?.rootViewController,
                visited: &visited
            ) else {
                return
            }
            coordinator.attach(to: tabBarController)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isObservationActive else { return }
                var currentVisited = Set<ObjectIdentifier>()
                guard let currentController = self.tabBarController ?? self.findTabBarController(
                    from: self.view.window?.rootViewController,
                    visited: &currentVisited
                ) else {
                    return
                }
                self.coordinator.attach(to: currentController)
            }
        }

        private func findTabBarController(
            from controller: UIViewController?,
            visited: inout Set<ObjectIdentifier>
        ) -> UITabBarController? {
            guard let controller else { return nil }
            guard visited.insert(ObjectIdentifier(controller)).inserted else { return nil }
            if let tabBarController = controller as? UITabBarController {
                return tabBarController
            }
            if let found = findTabBarController(from: controller.presentedViewController, visited: &visited) {
                return found
            }
            for child in controller.children {
                if let found = findTabBarController(from: child, visited: &visited) {
                    return found
                }
            }
            return nil
        }
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
        var onReselectHome: () -> Void
        private weak var observedController: UITabBarController?
        private weak var previousDelegate: UITabBarControllerDelegate?
        private weak var tabBarTapRecognizer: UITapGestureRecognizer?
        private var selectionBeforeTouch: RootTab?
        private var lastReselectUptime: TimeInterval = 0

        init(onReselectHome: @escaping () -> Void) {
            self.onReselectHome = onReselectHome
        }

        func attach(to tabBarController: UITabBarController) {
            if observedController !== tabBarController || tabBarController.delegate !== self {
                detach()
                previousDelegate = tabBarController.delegate
                observedController = tabBarController
                tabBarController.delegate = self
            }
            installTabBarTapRecognizer(on: tabBarController)
            TabBarControllerProxy.shared.attach(tabBarController)
        }

        func detach() {
            if let observedController, observedController.delegate === self {
                observedController.delegate = previousDelegate
            }
            if let tabBarTapRecognizer {
                tabBarTapRecognizer.view?.removeGestureRecognizer(tabBarTapRecognizer)
            }
            tabBarTapRecognizer = nil
            observedController = nil
            previousDelegate = nil
            TabBarControllerProxy.shared.attach(nil)
        }

        /// SwiftUI installs its own tab bar controller delegate, so the hook
        /// below can be replaced without notice and a re-tap would then go
        /// unnoticed. Reading the tap straight off the bar cannot be taken
        /// away by the framework, and both hooks funnel through the same
        /// debounce so a single tap never refreshes the feed twice.
        private func installTabBarTapRecognizer(on tabBarController: UITabBarController) {
            let tabBar = tabBarController.tabBar
            guard tabBarTapRecognizer?.view !== tabBar else { return }
            if let existing = tabBarTapRecognizer {
                existing.view?.removeGestureRecognizer(existing)
            }
            let recognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(handleTabBarTap(_:))
            )
            // The bar keeps its own tap handling; this recognizer only reports
            // where the touch landed.
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            tabBar.addGestureRecognizer(recognizer)
            tabBarTapRecognizer = recognizer
        }

        @objc private func handleTabBarTap(_ recognizer: UITapGestureRecognizer) {
            defer { selectionBeforeTouch = nil }
            guard recognizer.state == .ended,
                  let tabBarController = observedController else { return }
            let tabBar = tabBarController.tabBar
            let point = recognizer.location(in: tabBar)
            guard tabBar.bounds.contains(point) else { return }
            let itemFrames = RootTabHitTester.itemFrames(
                in: tabBar.bounds,
                itemCount: tabBar.items?.count ?? 0
            )
            let tappedTab = RootTabHitTester.tab(at: point, itemFrames: itemFrames)
            guard TabReselectPolicy.isReselect(
                tapped: tappedTab,
                selectionBeforeTouch: selectionBeforeTouch
            ) else { return }
            fireReselect()
        }

        /// Runs as the touch begins, before UIKit acts on the tap, so this is
        /// still the tab the user was looking at when they put their finger
        /// down. Reading the selection at tap time instead would count every
        /// switch back to 首页 as a re-tap and refresh a feed nobody re-tapped.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            selectionBeforeTouch = observedController.flatMap {
                RootTab(tabIndex: $0.selectedIndex)
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        private func fireReselect() {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastReselectUptime > 0.3 else { return }
            lastReselectUptime = now
            DispatchQueue.main.async(execute: onReselectHome)
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            shouldSelect viewController: UIViewController
        ) -> Bool {
            let permitsSelection = previousDelegate?.tabBarController?(
                tabBarController,
                shouldSelect: viewController
            ) ?? true
            guard permitsSelection else { return false }

            // `shouldSelect` runs before UIKit moves the selection, so here the
            // tapped controller still being the selected one already means the
            // user re-tapped the tab they were on.
            if tabBarController.selectedViewController === viewController,
               tabBarController.viewControllers?.first === viewController {
                fireReselect()
            }
            return true
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            didSelect viewController: UIViewController
        ) {
            previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || previousDelegate?.responds(to: aSelector) == true
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if previousDelegate?.responds(to: aSelector) == true {
                return previousDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

/// The single UIKit bridge to the shared tab bar. SwiftUI pages never reach
/// the UITabBarController directly: the thread detail asks for the bar to
/// disappear entirely (Coolapk-style, so its action bar sits at the screen
/// bottom), and scroll surfaces ask for the Instagram-style proportional
/// shrink while reading down. UIKit target-action wiring keeps this
/// main-thread-only by construction.
final class TabBarControllerProxy {
    static let shared = TabBarControllerProxy()

    private(set) weak var controller: UITabBarController?
    private var shrinkProgress: CGFloat = 0

    func attach(_ tabBarController: UITabBarController?) {
        guard controller !== tabBarController else { return }
        controller = tabBarController
        shrinkProgress = 0
        applyShrinkTransform()
    }

    /// 酷安式：进入帖子后 tab bar 整条消失，评论操作栏落到屏幕底部。
    /// `setTabBarHidden` is the system API on iOS 18+; earlier systems keep
    /// relying on SwiftUI's `.toolbar(.hidden, for: .tabBar)`.
    func setTabBarHidden(_ hidden: Bool, animated: Bool) {
        guard let controller else { return }
        if #available(iOS 18.0, *) {
            controller.setTabBarHidden(hidden, animated: animated)
        }
    }

    /// IG 式连续跟随：progress 0 = 完整，1 = 最小。由手指位移连续驱动，
    /// 没有阈值和状态开关，往哪个方向滑都不会抽搐。
    func applyShrinkDelta(_ delta: CGFloat) {
        let clamped = min(max(shrinkProgress + delta, 0), 1)
        guard clamped != shrinkProgress else { return }
        shrinkProgress = clamped
        applyShrinkTransform()
    }

    private func applyShrinkTransform() {
        guard let tabBar = controller?.tabBar, tabBar.bounds.height > 0 else { return }
        guard shrinkProgress > 0 else {
            if tabBar.transform != .identity {
                tabBar.transform = .identity
            }
            return
        }
        // Scale proportionally around the bar's own center — Instagram's
        // collapse keeps the full icon row, just smaller and centered.
        let scale = 1 - 0.2 * shrinkProgress
        let target = CGAffineTransform(
            translationX: tabBar.bounds.midX * (1 - scale),
            y: tabBar.bounds.midY * (1 - scale)
        ).scaledBy(x: scale, y: scale)
        if tabBar.transform != target {
            tabBar.transform = target
        }
    }
}

/// Hosts inside a scroll surface and forwards the pan direction to the shared
/// proxy. Only a target is added to the scroll view's existing pan
/// recognizer, so no second gesture competes with the system's.
private struct TabBarScrollDirectionReporter: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onHierarchyChange = { [weak coordinator = context.coordinator] attachmentView in
            coordinator?.scheduleAttachment(from: attachmentView)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.scheduleAttachment(from: uiView)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        uiView.onHierarchyChange = nil
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        var onHierarchyChange: ((AttachmentView) -> Void)?
        private(set) var hierarchyGeneration: UInt = 0

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            hierarchyGeneration &+= 1
            onHierarchyChange?(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            hierarchyGeneration &+= 1
            onHierarchyChange?(self)
        }
    }

    final class Coordinator: NSObject {
        private weak var attachedScrollView: UIScrollView?
        private weak var panRecognizer: UIPanGestureRecognizer?
        private var pendingAttachment: DispatchWorkItem?
        private var attachmentRequestID: UInt = 0
        // Finger travel that maps to the bar's full shrink range.
        private static let travelPerFullShrink: CGFloat = 110

        func scheduleAttachment(from view: AttachmentView) {
            attachmentRequestID &+= 1
            let requestID = attachmentRequestID
            let generation = view.hierarchyGeneration
            pendingAttachment?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view else { return }
                guard self.attachmentRequestID == requestID,
                      generation == view.hierarchyGeneration else { return }
                self.pendingAttachment = nil
                self.attach(to: Self.enclosingScrollView(startingAt: view))
            }
            pendingAttachment = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        func detach() {
            attachmentRequestID &+= 1
            pendingAttachment?.cancel()
            pendingAttachment = nil
            panRecognizer?.removeTarget(self, action: #selector(handlePan(_:)))
            panRecognizer = nil
            attachedScrollView = nil
        }

        private func attach(to scrollView: UIScrollView?) {
            detach()
            guard let scrollView else { return }
            attachedScrollView = scrollView
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            panRecognizer = scrollView.panGestureRecognizer
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .changed, let scrollView = attachedScrollView else { return }
            // Continuous, position-driven: each finger delta nudges the bar
            // toward (or back from) its shrunken state. No thresholds, no
            // state flips, so direction changes and finger slowdowns stay
            // perfectly smooth — the way Instagram's bar tracks the finger.
            let translation = pan.translation(in: scrollView).y
            pan.setTranslation(.zero, in: scrollView)
            guard translation != 0 else { return }
            TabBarControllerProxy.shared.applyShrinkDelta(
                -translation / Self.travelPerFullShrink
            )
        }

        private static func enclosingScrollView(startingAt view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    return scrollView
                }
                current = candidate.superview
            }
            return nil
        }
    }
}

extension View {
    /// Place inside a scroll surface's content so its pan direction reaches
    /// the shared tab bar proxy (Instagram-style proportional shrink while
    /// reading down, restore on the way back).
    func reportsScrollDirectionToTabBar() -> some View {
        background(TabBarScrollDirectionReporter())
    }
}

/// A tab bar re-tap only counts when the tapped item was already the selected
/// one. UIKit updates the selection while it handles the same touch, so the
/// gesture hook has to compare against the selection captured as the touch
/// began rather than the selection at tap time.
enum TabReselectPolicy {
    static func isReselect(tapped: RootTab?, selectionBeforeTouch: RootTab?) -> Bool {
        guard let tapped, let selectionBeforeTouch else { return false }
        return tapped == selectionBeforeTouch
    }
}

enum RootTabHitTester {
    static func tab(at point: CGPoint, itemFrames: [CGRect]) -> RootTab? {
        guard let index = itemFrames.firstIndex(where: { $0.contains(point) }) else { return nil }
        return RootTab(tabIndex: index)
    }

    /// `UITabBar` splits its own width evenly between its items and publishes
    /// no API for their frames, so equal slices of the bar are the closest
    /// available approximation of where each item sits.
    static func itemFrames(in bounds: CGRect, itemCount: Int) -> [CGRect] {
        guard itemCount > 0, bounds.width > 0 else { return [] }
        let itemWidth = bounds.width / CGFloat(itemCount)
        return (0..<itemCount).map { index in
            CGRect(
                x: bounds.minX + itemWidth * CGFloat(index),
                y: bounds.minY,
                width: itemWidth,
                height: bounds.height
            )
        }
    }
}

extension RootTab {
    init?(tabIndex: Int) {
        switch tabIndex {
        case 0:
            self = .home
        case 1:
            self = .forums
        case 2:
            self = .me
        default:
            return nil
        }
    }
}
