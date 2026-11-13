import AppKit
import SwiftUI
import Combine

@MainActor
final class MenubarController {
    private let state: AppState
    private let systemExtension: SystemExtensionManager
    private let windows: WindowManager
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var trafficCancellable: AnyCancellable?

    init(state: AppState, systemExtension: SystemExtensionManager, windows: WindowManager) {
        self.state = state
        self.systemExtension = systemExtension
        self.windows = windows
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let popoverView = MenubarPopoverView(systemExtension: systemExtension,
                                              close: { [weak self] in self?.popover.performClose(nil) })
            .environmentObject(state)
            .environmentObject(windows)
            .frame(width: MenubarPopoverView.width)
        let hosting = NSHostingController(rootView: popoverView)
        // The popover is as tall as what it has to say. Pinned to 540 points
        // it clipped its own header and its last menu item as soon as a helper
        // banner appeared, because the content simply overflowed the frame
        // (#91). `preferredContentSize` keeps the popover tracking the height
        // SwiftUI actually needs, banner or no banner.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        render()

        // Redraw on traffic, helper health, filter readiness and when the
        // user toggles the speed readout in Settings.
        trafficCancellable = Publishers.MergeMany(
            state.$trafficHistory.map { _ in () }.eraseToAnyPublisher(),
            state.$helperConnected.map { _ in () }.eraseToAnyPublisher(),
            state.$helperInstallState.map { _ in () }.eraseToAnyPublisher(),
            state.$filterSnapshotStatus.map { _ in () }.eraseToAnyPublisher(),
            systemExtension.$status.map { _ in () }.eraseToAnyPublisher(),
            state.$showSpeedsInMenuBar.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.render() }
    }

    /// Takes the status item out of the menu bar before the process goes away.
    ///
    /// Quitting removes it anyway, but the uninstall ends with a bundle that is
    /// already in the Trash, and an icon that outlives the app it belongs to is
    /// exactly what made "FreeSnitch has been removed" read as a lie (#133).
    func removeStatusItem() {
        guard let statusItem else { return }
        trafficCancellable?.cancel()
        trafficCancellable = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    /// Opens the panel without a click, so the one screen that is reached only
    /// from the menu bar can still be reviewed on screen before it ships.
    func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleClick(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        // Same numbering as the sidebar and the app menu, so this menu teaches
        // the binding instead of contradicting it. All five pages are listed:
        // leaving two of them out was how Profiles ended up unreachable from
        // the keyboard.
        menu.addItem(makeItem("Network Monitor", #selector(openMonitor), keyEq: "1", modifiers: [.command]))
        menu.addItem(makeItem("Rules", #selector(openRules), keyEq: "2", modifiers: [.command]))
        menu.addItem(makeItem("Insights", #selector(openInsights), keyEq: "3", modifiers: [.command]))
        menu.addItem(makeItem("Profiles", #selector(openProfiles), keyEq: "4", modifiers: [.command]))
        // Settings keeps Command-comma as well: that one is a system-wide
        // convention and people press it wherever Settings happens to sit.
        menu.addItem(makeItem("Settings", #selector(openSettings), keyEq: ",", modifiers: [.command]))
        menu.addItem(.separator())
        let modeMenu = NSMenu(title: "Mode")
        modeMenu.addItem(makeItem("Alert", #selector(modeAlert), keyEq: "", state: state.mode == .alert ? .on : .off))
        modeMenu.addItem(makeItem("Silent Allow", #selector(modeAllow), keyEq: "", state: state.mode == .silentAllow ? .on : .off))
        modeMenu.addItem(makeItem("Silent Deny", #selector(modeDeny), keyEq: "", state: state.mode == .silentDeny ? .on : .off))
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit FreeSnitch", #selector(quit), keyEq: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeItem(
        _ title: String,
        _ sel: Selector,
        keyEq: String,
        modifiers: NSEvent.ModifierFlags = [],
        state: NSControl.StateValue = .off
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: keyEq)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.state = state
        return item
    }

    @objc private func openMonitor() { windows.showNetworkMonitor() }
    @objc private func openRules() { windows.showRulesManager() }
    @objc private func openInsights() { windows.showInsights() }
    @objc private func openProfiles() { windows.showProfiles() }
    @objc private func openSettings() { windows.showSettings() }
    @objc private func modeAlert() { state.setMode(.alert) }
    @objc private func modeAllow() { state.setMode(.silentAllow) }
    @objc private func modeDeny() { state.setMode(.silentDeny) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Draws the status item the way AppKit expects: a template symbol that the
    /// system recolours for light, dark, high-contrast and tinted menu bars.
    /// The previous version hand-drew pink and blue text into a non-template
    /// bitmap, which is what users saw as "the menu icon is 2 colours".
    private func render() {
        guard let statusItem, let button = statusItem.button else { return }

        let filtering = isFilterReady
        let symbol = filtering ? "record.circle" : "shield.slash"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FreeSnitch")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image

        if state.showSpeedsInMenuBar, let image {
            // Compact readout: the two rates stacked in small type beside the
            // icon, drawn as one template image so the item stays narrow and
            // does not change width as the numbers change.
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageOnly
            button.title = ""
            button.image = Self.compactImage(icon: image,
                                             down: compactSpeed(state.currentIn),
                                             up: compactSpeed(state.currentOut))
        } else {
            statusItem.length = NSStatusItem.squareLength
            button.imagePosition = .imageOnly
            button.title = ""
        }

        button.toolTip = tooltip
        button.setAccessibilityLabel("FreeSnitch: \(tooltip)")
    }

    private var isFilterReady: Bool {
        systemExtension.status == .active && state.filterSnapshotStatus.state == .ready
    }

    private var tooltip: String {
        guard isFilterReady else {
            switch systemExtension.status {
            case .needsApproval:
                return "Firewall not filtering. Approve FreeSnitch under General > Login Items & Extensions > Network Extensions"
            case .failed(let message):
                return "Firewall not filtering: \(message)"
            case .unsupported:
                return "Firewall not filtering. Network Extension unavailable in this build"
            case .activating:
                return "Firewall not filtering yet. Network Extension is starting"
            case .active:
                switch state.filterSnapshotStatus.state {
                case .unavailable:
                    return "Firewall not filtering. Rule snapshot unavailable"
                case .invalid:
                    return "Firewall not filtering. Rule snapshot invalid"
                case .ready:
                    break
                }
            case .idle:
                return "Firewall not filtering yet"
            }
            return "Firewall not filtering"
        }
        if !state.helperConnected {
            return "Firewall filtering is active. Traffic monitor helper is not connected"
        }
        return "↓ \(PSFormat.bytesPerSec(state.currentIn))  ↑ \(PSFormat.bytesPerSec(state.currentOut))"
    }

    /// At most four characters: "0K", "489K", "1.2M", "12M", "3.4G".
    private func compactSpeed(_ n: Int64) -> String {
        let k = Double(max(n, 0)) / 1024
        if k < 999.5 { return String(format: "%.0fK", k) }
        let m = k / 1024
        if m < 9.95 { return String(format: "%.1fM", m) }
        if m < 999.5 { return String(format: "%.0fM", m) }
        let g = m / 1024
        return g < 9.95 ? String(format: "%.1fG", g) : String(format: "%.0fG", g)
    }

    private static func compactImage(icon: NSImage, down: String, up: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // Fixed width from the widest possible value, so the item never jitters.
        let textWidth = ceil(("↓999K" as NSString).size(withAttributes: attrs).width)
        let lineHeight = ceil(font.ascender - font.descender)
        let height: CGFloat = 22
        let iconSize = NSSize(width: 14, height: 14)
        let gap: CGFloat = 3
        let size = NSSize(width: iconSize.width + gap + textWidth, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (height - iconSize.height) / 2,
                                 width: iconSize.width, height: iconSize.height))
            let x = iconSize.width + gap
            let top = (height + 2 * lineHeight) / 2 - lineHeight
            ("↓" + down as NSString).draw(at: NSPoint(x: x, y: top - 1), withAttributes: attrs)
            ("↑" + up as NSString).draw(at: NSPoint(x: x, y: top - lineHeight + 1), withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension WindowManager: ObservableObject {}
