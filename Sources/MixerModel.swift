import AppKit
import CoreAudio
import ServiceManagement

final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var volumes: [String: Double]
    @Published private(set) var muted: Set<String>
    @Published private(set) var lastError: String?

    private var taps: [String: AppTap] = [:]
    private var icons: [String: NSImage] = [:]
    private var pollTimer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        volumes = defaults.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        muted = Set(defaults.stringArray(forKey: "muted") ?? [])
        // Reacting to the process list (instead of polling) applies a saved volume as soon as an app opens audio.
        listen(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.syncTaps() }
        refresh()
    }

    func volume(for app: AudioApp) -> Double { volumes[app.id] ?? 1 }

    func isMuted(_ app: AudioApp) -> Bool { muted.contains(app.id) }

    func setVolume(_ volume: Double, for app: AudioApp) {
        volumes[app.id] = volume >= 0.995 ? nil : volume
        save()
    }

    func toggleMute(_ app: AudioApp) {
        if muted.remove(app.id) == nil { muted.insert(app.id) }
        save()
    }

    func resetAll() {
        volumes = [:]
        muted = []
        save()
    }

    func refresh() {
        let current = AudioProcessMonitor.currentApps()
        if current != apps { apps = current }
        syncTaps()
    }

    /// Only needed to update the "playing" indicators while the menu is open.
    func setLivePolling(_ enabled: Bool) {
        pollTimer?.invalidate()
        pollTimer = enabled ? Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() } : nil
    }

    func stopAll() {
        taps.removeAll()
    }

    func icon(for app: AudioApp) -> NSImage {
        if let icon = icons[app.id] { return icon }
        let icon = app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        icons[app.id] = icon
        return icon
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    private func save() {
        defaults.set(volumes, forKey: "volumes")
        defaults.set(Array(muted), forKey: "muted")
        syncTaps()
    }

    /// Squared so the slider feels linear to the ear rather than dropping off only at the very end.
    private func gain(for id: String) -> Float {
        muted.contains(id) ? 0 : Float(pow(volumes[id] ?? 1, 2))
    }

    /// Apps at 100% are left untouched: no tap, no added latency.
    private func syncTaps() {
        guard let device = try? CA.defaultOutputDevice(), let deviceUID = try? CA.deviceUID(device) else { return }
        var wanted = Set<String>()

        for app in apps {
            let gain = gain(for: app.id)
            guard gain < 0.999 else { continue }
            wanted.insert(app.id)

            if let tap = taps[app.id], tap.processObjectIDs == app.processObjectIDs, tap.outputDeviceUID == deviceUID {
                tap.gain = gain
                continue
            }
            // Release the previous tap first so the same processes are never tapped twice.
            taps[app.id] = nil
            do {
                taps[app.id] = try AppTap(name: app.name, processObjectIDs: app.processObjectIDs, outputDevice: device, gain: gain)
                if lastError?.hasPrefix(app.name) == true { lastError = nil }
            } catch {
                lastError = "\(app.name): \(error)"
            }
        }

        for id in Array(taps.keys) where !wanted.contains(id) {
            taps[id] = nil
        }
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = CA.address(selector)
        AudioObjectAddPropertyListenerBlock(.system, &address, .main) { _, _ in handler() }
    }
}
