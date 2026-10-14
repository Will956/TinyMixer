import AppKit
import CoreAudio
import ServiceManagement

final class MixerModel: ObservableObject {
    /// Notifications & alerts first, then apps currently playing sound.
    @Published private(set) var visibleApps: [AudioApp] = []
    @Published private(set) var volumes: [String: Double]
    @Published private(set) var muted: Set<String>
    @Published private(set) var lastError: String?

    /// Every app with an audio process, playing or not, so saved volumes apply as soon as it starts playing.
    private var apps: [AudioApp] = []
    private var taps: [String: AppTap] = [:]
    private var icons: [String: NSImage] = [:]
    private var pollTimer: Timer?
    private var isMenuOpen = false
    // Rows stay put until the menu closes, so a pause in playback doesn't pull a slider from under the cursor.
    private var shownWhileOpen: Set<String> = []
    private let defaults = UserDefaults.standard

    init() {
        volumes = defaults.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        muted = Set(defaults.stringArray(forKey: "muted") ?? [])
        // Reacting to the process list (instead of polling) applies a saved volume as soon as an app opens audio.
        listen(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.syncTaps() }
        listen(kAudioHardwarePropertyDefaultSystemOutputDevice) { [weak self] in self?.syncTaps() }
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
        apps = AudioProcessMonitor.currentApps()
        updateVisibleApps()
        syncTaps()
    }

    /// Polls while open since playback starting or stopping doesn't change the process list.
    func setMenuOpen(_ open: Bool) {
        isMenuOpen = open
        shownWhileOpen = []
        pollTimer?.invalidate()
        pollTimer = open ? Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() } : nil
        if open { refresh() }
    }

    private func updateVisibleApps() {
        let visible = apps
            .filter { $0.id == AudioProcessMonitor.alertsID || $0.isPlaying || shownWhileOpen.contains($0.id) }
            .sorted { (sortRank($0), $0.name.lowercased()) < (sortRank($1), $1.name.lowercased()) }
        if isMenuOpen { shownWhileOpen.formUnion(visible.map(\.id)) }
        if visible != visibleApps { visibleApps = visible }
    }

    private func sortRank(_ app: AudioApp) -> Int { app.id == AudioProcessMonitor.alertsID ? 0 : 1 }

    func stopAll() {
        taps.removeAll()
    }

    func icon(for app: AudioApp) -> NSImage {
        if let icon = icons[app.id] { return icon }
        let icon = app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: app.id == AudioProcessMonitor.alertsID ? "bell.fill" : "app", accessibilityDescription: nil)!
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
        guard let output = try? CA.defaultOutputDevice() else { return }
        let alertOutput = (try? CA.defaultSystemOutputDevice()) ?? output
        var wanted = Set<String>()

        for app in apps {
            let gain = gain(for: app.id)
            guard gain < 0.999 else { continue }
            wanted.insert(app.id)

            let device = app.id == AudioProcessMonitor.alertsID ? alertOutput : output
            guard let deviceUID = try? CA.deviceUID(device) else { continue }

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
                NSLog("TinyMixer: could not control %@: %@", app.name, "\(error)")
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
