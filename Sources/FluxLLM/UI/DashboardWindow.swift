import AppKit

/// Owns dashboard presentation and the readable floor enforced by AppKit.
/// SwiftUI never feeds an expanded chart's fitting size back into these limits.
@MainActor
class DashboardWindow: NSWindow, NSWindowDelegate {
    private(set) var isDashboardOpen = false
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
    }

    func windowWillClose(_ notification: Notification) {
        guard isDashboardOpen else { return }
        isDashboardOpen = false
        setActivationPolicy(.accessory)
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
