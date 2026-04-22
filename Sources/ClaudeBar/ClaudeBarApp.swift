import SwiftUI
import AppKit
import Combine

@main
struct ClaudeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: UsageMonitor!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        monitor = UsageMonitor()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.makeStatusIcon()
            button.imagePosition = .imageLeading
            button.title = " …"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuView(monitor: monitor)
        )

        monitor.$menuBarText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)
        monitor.$menuBarColor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItemTitle() }
            .store(in: &cancellables)
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }
        // UsageMonitor still prefixes the text with "◐ " — strip that now
        // that we render the bar-chart SF Symbol next to it.
        var text = monitor.menuBarText
        if text.hasPrefix("◐ ") { text = String(text.dropFirst(2)) }
        text = " " + text

        let color: NSColor
        switch monitor.menuBarColor {
        case .green: color = .systemGreen
        case .amber: color = .systemOrange
        case .red: color = .systemRed
        case .neutral: color = .controlTextColor
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        let attr = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color, .font: font]
        )
        // macOS 26 can drop the template image when the attributed title is
        // set if the icon isn't reseated. Reassign the image + position every
        // update so both stay visible in the bar.
        if button.image == nil { button.image = Self.makeStatusIcon() }
        button.imagePosition = .imageLeading
        button.attributedTitle = attr
        // Only tint the template image on colored states. Leaving it nil for
        // neutral lets the system resolve the menu-bar appearance correctly,
        // which fixes the "invisible icon" regression on macOS 26.
        switch monitor.menuBarColor {
        case .neutral:
            button.contentTintColor = nil
        case .green, .amber, .red:
            button.contentTintColor = color
        }
    }

    private static func makeStatusIcon() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let icon = NSImage(
            systemSymbolName: "chart.bar.xaxis",
            accessibilityDescription: "Claude usage"
        )?.withSymbolConfiguration(config)
        icon?.isTemplate = true
        return icon
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu(from: sender)
            return
        }
        togglePopover(from: sender)
    }

    private func togglePopover(from sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            monitor.refresh()
        }
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshFromMenu() { monitor.refresh() }
}
