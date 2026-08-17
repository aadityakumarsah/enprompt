import AppKit
import SwiftUI

/// Manages the menu bar status item.
///
/// Click: show/hide the enprompt popover. Enhancement is triggered ONLY by the
/// keyboard (double-tap ⌥ to expand, hold ⌥ to dictate) - never by clicking
/// the menu bar icon.
@MainActor
final class StatusItemController: NSObject {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = appIconImage()
            button.image = image
            button.imageScaling = .scaleProportionallyUpOrDown
            button.toolTip = "enprompt - tap ⌥ twice to expand text, hold ⌥ to dictate"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        statusItem = item
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showPopoverRequested(_:)),
            name: .enpromptShowPopover,
            object: nil
        )
    }

    @objc private func showPopoverRequested(_ note: Notification) {
        if let popover, popover.isShown { return }
        showPopover()
    }

    /// The enprompt logo (mac-nav-icon.icns from the app bundle), sized for the
    /// menu bar. Template image: macOS auto-renders it black on light menu bars
    /// and white on dark ones so it never disappears.
    private func appIconImage() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "mac-nav-icon", withExtension: "icns"),
              let image = NSImage(contentsOf: iconURL) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 440)
        popover.contentViewController = NSHostingController(
            rootView: EnpromptMenuView().environmentObject(AppState.shared)
        )
        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        self.popover = popover
    }
}