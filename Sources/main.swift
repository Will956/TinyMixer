import AppKit
import SwiftUI

if CommandLine.arguments.contains("--list") {
    for app in AudioProcessMonitor.currentApps() {
        print("\(app.isPlaying ? "▶" : " ") \(app.name) [\(app.id)] process objects: \(app.processObjectIDs)")
    }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MixerModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "TinyMixer")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: MixerView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopAll()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) { model.setLivePolling(true) }

    func popoverDidClose(_ notification: Notification) { model.setLivePolling(false) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
