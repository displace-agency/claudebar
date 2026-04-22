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
        statusItem.isVisible = true
        statusItem.behavior = []
        statusItem.autosaveName = "agency.displace.ClaudeBar.status"
        if let button = statusItem.button {
            // Render the whole menu bar label into a single bitmap image and
            // hand that to the button. This bypasses the macOS 26 bug where
            // NSStatusBarButton's cell draws attributedTitle + template images
            // at zero alpha on ad-hoc-signed apps.
            button.image = Self.renderBarImage(text: "⏺ …", color: .white)
            button.imagePosition = .imageOnly
            button.title = ""
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
        var text = monitor.menuBarText
        if text.hasPrefix("◐ ") { text = String(text.dropFirst(2)) }

        let color: NSColor
        switch monitor.menuBarColor {
        case .green: color = .systemGreen
        case .amber: color = .systemOrange
        case .red: color = .systemRed
        case .neutral: color = .white
        }
        button.image = Self.renderBarImage(text: "⏺ " + text, color: color)
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = nil
    }

    /// Pre-renders the menu bar label into a single non-template NSImage.
    /// Works around a macOS 26 regression where NSStatusBarButton draws
    /// attributedTitle + template images at zero alpha for ad-hoc signed apps.
    private static func renderBarImage(text: String, color: NSColor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attr = NSAttributedString(string: text, attributes: attrs)

        let textSize = attr.size()
        let padding: CGFloat = 4
        let size = NSSize(
            width: ceil(textSize.width) + padding * 2,
            height: NSStatusBar.system.thickness
        )

        let image = NSImage(size: size)
        image.lockFocus()
        let origin = NSPoint(x: padding, y: (size.height - textSize.height) / 2)
        attr.draw(at: origin)
        image.unlockFocus()
        image.isTemplate = false
        return image
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
