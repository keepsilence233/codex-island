import SwiftUI
import Combine

@MainActor
final class IslandModel: ObservableObject {
    enum State {
        case compact
        case peek
        case expanded
    }

    @Published var state: State = .compact
    @Published var size: CGSize = .zero
    /// Horizontal offset of the silhouette within the host window. Used in
    /// compact / peek states to keep the physical notch visually aligned
    /// when only one provider is visible — the silhouette shrinks
    /// asymmetrically (only the visible side keeps its tab + pill slot)
    /// and gets shifted so its notch portion stays under the screen
    /// notch. Always 0 when both providers are visible (or both hidden)
    /// and in expanded state.
    @Published var silhouetteOffsetX: CGFloat = 0
    @Published var notch: NotchInfo

    /// Side extension that houses each brand logo in compact state.
    let tabWidth: CGFloat = 38

    /// Per-side outboard slot that houses the peek-state percentage pill.
    /// Sized for "100% · Nh" worst case at the chosen pill typography.
    /// Fixed (not text-measured) so percentage updates don't jitter the
    /// silhouette width during refresh. Grown only on sides whose provider
    /// is visible — see `recomputeSize`. The silhouette is then offset
    /// within the host so its notch portion stays under the physical
    /// notch when only one side extends.
    let pillSlotWidth: CGFloat = 78

    /// Visible expanded panel width.
    private let expandedWidth: CGFloat = 720

    /// Visible expanded panel content height. The shape sits flush with the
    /// top of the screen, so we add notch.height of "filler" so visible
    /// content sits BELOW the notch line.
    private let expandedContentHeight: CGFloat = 172

    /// Detection-pure notch from `NotchInfo.detect`. Kept separate from
    /// `notch` (which has the user's spacing override applied) so
    /// `updateNotch`'s diff guard isn't confused by override-induced
    /// width changes that originate from the store, not the screen.
    private var rawNotch: NotchInfo

    private var subs: Set<AnyCancellable> = []

    init(notch: NotchInfo) {
        self.rawNotch = notch
        self.notch = Self.applyOverride(to: notch, width: IslandSpacingStore.shared.width)
        recomputeSize()
        subscribeToSpacingStore()
        subscribeToVisibilityStore()
    }

    func setState(_ new: State) {
        guard new != state else { return }
        state = new
        recomputeSize()
    }

    func updateNotch(_ raw: NotchInfo) {
        guard raw.width != rawNotch.width
            || raw.height != rawNotch.height
            || raw.hasNotch != rawNotch.hasNotch else { return }
        rawNotch = raw
        notch = Self.applyOverride(to: raw, width: IslandSpacingStore.shared.width)
        recomputeSize()
    }

    /// Substitutes the user's chosen non-notch width for the detected
    /// fallback. On notched screens the raw notch is returned untouched —
    /// the override is meaningless there (you can't shrink a physical
    /// notch).
    private static func applyOverride(to raw: NotchInfo, width: CGFloat) -> NotchInfo {
        if raw.hasNotch { return raw }
        return NotchInfo(width: width, height: raw.height, hasNotch: false)
    }

    /// Re-applies the override and re-computes size whenever the user
    /// changes spacing mode. The `mode` value here is the *new* value from
    /// the closure parameter — `IslandSpacingStore.shared.mode` would be
    /// the *old* value at this point because `@Published` emits during
    /// willSet, before the property assignment lands. Reading `mode.width`
    /// off the closure parameter sidesteps the race.
    ///
    /// Wrapped in `withAnimation(.openMorph)` so the silhouette springs to
    /// its new width with the same feel as a state morph.
    private func subscribeToSpacingStore() {
        IslandSpacingStore.shared.$mode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self else { return }
                let new = Self.applyOverride(to: self.rawNotch, width: mode.width)
                guard new.width != self.notch.width else { return }
                withAnimation(.openMorph) {
                    self.notch = new
                    self.recomputeSize()
                }
            }
            .store(in: &subs)
    }

    /// Re-recomputes silhouette size + offset when the user toggles a
    /// provider's visibility. Wrapped in `withAnimation(.openMorph)` so
    /// the silhouette morphs with the same spring as a state change —
    /// matches the feel of the SettingsToggle action which also uses
    /// `openMorph`. CombineLatest keeps both values fresh; dropFirst
    /// skips the initial emit at subscription time.
    private func subscribeToVisibilityStore() {
        Publishers.CombineLatest(
            ProviderVisibilityStore.shared.$claudeVisible,
            ProviderVisibilityStore.shared.$codexVisible
        )
        .dropFirst()
        .sink { [weak self] _, _ in
            guard let self else { return }
            withAnimation(.openMorph) {
                self.recomputeSize()
            }
        }
        .store(in: &subs)
    }

    /// Compact + peek silhouettes shrink asymmetrically when one provider
    /// is hidden — the hidden side's tab (and in peek, pill slot) gets
    /// dropped entirely instead of left as empty negative space. The
    /// silhouette is then offset within the window so its notch portion
    /// stays geometrically aligned with the screen notch (otherwise
    /// shrinking only one side would leave the silhouette's notch
    /// off-center from the physical one).
    ///
    /// Both-on: symmetric, offset 0 (existing behavior).
    /// Both-off: silhouette is just the notch shape — minimal "covered
    /// notch" affordance the user can still click to reach Settings.
    /// Expanded: always full-width; offset 0.
    private func recomputeSize() {
        let viz = ProviderVisibilityStore.shared
        let claudeOn = viz.claudeVisible
        let codexOn = viz.codexVisible

        switch state {
        case .compact:
            let leftTab: CGFloat = claudeOn ? tabWidth : 0
            let rightTab: CGFloat = codexOn ? tabWidth : 0
            size = CGSize(
                width: notch.width + leftTab + rightTab,
                height: notch.height
            )
            silhouetteOffsetX = -(leftTab - rightTab) / 2
        case .peek:
            // Pill slot drops with the tab on hidden sides — the pill
            // itself is already opacity 0 so dropping its slot tightens
            // the silhouette without losing any rendered chrome.
            let leftExt: CGFloat = claudeOn ? (tabWidth + pillSlotWidth) : 0
            let rightExt: CGFloat = codexOn ? (tabWidth + pillSlotWidth) : 0
            size = CGSize(
                width: notch.width + leftExt + rightExt,
                height: notch.height
            )
            silhouetteOffsetX = -(leftExt - rightExt) / 2
        case .expanded:
            size = CGSize(
                width: expandedWidth,
                height: expandedContentHeight + notch.height
            )
            silhouetteOffsetX = 0
        }
    }
}
