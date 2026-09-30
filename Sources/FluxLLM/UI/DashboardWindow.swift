import AppKit

/// Owns dashboard presentation and the readable floor enforced by AppKit.
/// SwiftUI never feeds an expanded chart's fitting size back into these limits.
@MainActor
class DashboardWindow: NSWindow, NSWindowDelegate {
    private(set) var isDashboardOpen = false
    private(set) var isPresentationContentActive = false
    private var makePresentationContent: (() -> NSViewController)?
    private var presentationVisibilityChanged: ((Bool) -> Void)?
    private var visibilityGeneration = 0
    private let placeholder = NSViewController()
    var setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void = {
        _ = NSApp.setActivationPolicy($0)
    }

    func present() {
        if !isDashboardOpen {
            isDashboardOpen = true
            setActivationPolicy(.regular)
        }
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
        schedulePresentationUpdate()
    }

    func windowWillClose(_ notification: Notification) {
        setPresentationContentActive(false)
        guard isDashboardOpen else { return }
        isDashboardOpen = false
        setActivationPolicy(.accessory)
    }

    /// A closed window preserves its frame and native sizing behavior, without
    /// retaining an observing SwiftUI host. The factory owns only light state.
    func configurePresentation(
        makeContent: @escaping () -> NSViewController,
        visibilityChanged: @escaping (Bool) -> Void
    ) {
        makePresentationContent = makeContent
        presentationVisibilityChanged = visibilityChanged
        placeholder.view = NSView(frame: NSRect(origin: .zero, size: contentLayoutRect.size))
        replacePresentationContent(with: placeholder)
    }

    /// Kept separate from content attachment so lifecycle tests can exercise the
    /// native event sequence without depending on another app's window stacking.
    var presentationIsVisible: Bool {
        isDashboardOpen && isVisible && !isMiniaturized && occlusionState.contains(.visible)
    }

    func synchronizePresentationVisibility() {
        setPresentationContentActive(presentationIsVisible)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        schedulePresentationUpdate()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        setPresentationContentActive(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        schedulePresentationUpdate()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        setPresentationContentActive(false)
    }

    private func schedulePresentationUpdate() {
        visibilityGeneration &+= 1
        let expected = visibilityGeneration
        // AppKit can notify during SwiftUI layout. Change host ownership only
        // after that layout pass and ignore superseded native notifications.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibilityGeneration == expected else { return }
            self.synchronizePresentationVisibility()
        }
    }

    private func setPresentationContentActive(_ active: Bool) {
        guard makePresentationContent != nil, active != isPresentationContentActive else { return }
        isPresentationContentActive = active
        presentationVisibilityChanged?(active)
        if active {
            if let controller = makePresentationContent?() {
                replacePresentationContent(with: controller)
            }
        } else {
            replacePresentationContent(with: placeholder)
        }
    }

    private func replacePresentationContent(with controller: NSViewController) {
        // AppKit sizes a window to the incoming controller's view. Lazy hosts
        // and the reusable placeholder must adopt the user's current geometry,
        // rather than feeding their initial/fitting size back into the window.
        let preservedFrame = frame
        let contentSize = contentRect(forFrameRect: preservedFrame).size
        controller.view.setFrameSize(contentSize)
        contentViewController = controller
        if frame != preservedFrame { setFrame(preservedFrame, display: false) }
    }

    override func setContentSize(_ size: NSSize) {
        let allowed = DashboardSizingPolicy.constrainedContentSize(size)
        updateResizeLimits(for: allowed)
        super.setContentSize(allowed)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var proposed = contentRect(forFrameRect: NSRect(origin: frame.origin, size: frameSize)).size
        let narrowMinimum = DashboardSizingPolicy.minimumContentSize(
            forWidth: DashboardSizingPolicy.minimumWidth)
        let currentWidth = contentRect(forFrameRect: frame).width
        if currentWidth >= DashboardSizingPolicy.narrowLayoutThreshold,
            proposed.width < DashboardSizingPolicy.narrowLayoutThreshold,
            proposed.height < narrowMinimum.height
        {
            // A width-only drag must stop before controls stack, rather than
            // growing the window vertically to accommodate the narrow layout.
            proposed.width = DashboardSizingPolicy.narrowLayoutThreshold
        }
        let allowed = DashboardSizingPolicy.constrainedContentSize(proposed)
        updateResizeLimits(for: allowed)
        return frameRect(forContentRect: NSRect(origin: .zero, size: allowed)).size
    }

    func windowDidResize(_ notification: Notification) {
        updateResizeLimits(for: contentRect(forFrameRect: frame).size)
    }

    private func updateResizeLimits(for size: NSSize) {
        let minimum = DashboardSizingPolicy.minimumContentSize(forWidth: size.width)
        let narrowMinimum = DashboardSizingPolicy.minimumContentSize(
            forWidth: DashboardSizingPolicy.minimumWidth)
        let width =
            size.height >= narrowMinimum.height
            ? DashboardSizingPolicy.minimumWidth : DashboardSizingPolicy.narrowLayoutThreshold
        let limits = NSSize(width: width, height: minimum.height)
        if contentMinSize != limits {
            contentMinSize = limits
        }
    }
}
