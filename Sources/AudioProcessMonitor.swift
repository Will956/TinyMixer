import AppKit
import CoreAudio

/// One user-facing app, possibly backed by several audio processes (e.g. Electron helpers).
struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool
}

enum AudioProcessMonitor {
    private static let webKitID = "com.apple.WebKit"

    static func currentApps() -> [AudioApp] {
        let processes = (try? CA.objectIDs(.system, kAudioHardwarePropertyProcessObjectList)) ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var appsByID: [String: AudioApp] = [:]

        for process in processes {
            guard let pid = try? CA.value(process, kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid != ownPID,
                  let owner = owningApp(pid: pid, bundleID: (try? CA.string(process, kAudioProcessPropertyBundleID)) ?? "")
            else { continue }

            let playing = ((try? CA.value(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            if var existing = appsByID[owner.id] {
                existing.processObjectIDs.append(process)
                existing.isPlaying = existing.isPlaying || playing
                appsByID[owner.id] = existing
            } else {
                appsByID[owner.id] = AudioApp(
                    id: owner.id, name: owner.name, bundlePath: owner.path,
                    processObjectIDs: [process], isPlaying: playing
                )
            }
        }

        return appsByID.values
            .map { app in var app = app; app.processObjectIDs.sort(); return app }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    /// Helpers live inside the main bundle (Slack.app/Contents/Frameworks/Slack Helper.app),
    /// so the outermost `.app` in the executable path is the app the user recognizes.
    private static func owningApp(pid: pid_t, bundleID: String) -> (id: String, name: String, path: String?)? {
        // Safari and other WebKit views play media from a shared system GPU process outside any .app.
        if bundleID.hasPrefix(webKitID) {
            let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")?.path
            return (webKitID, "Safari & web views", safari)
        }

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let components = String(cString: buffer).split(separator: "/", omittingEmptySubsequences: false)
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }

        let appPath = components[...appIndex].joined(separator: "/")
        // System agents (loginwindow, PowerChime, Control Center…) only add noise to the list.
        guard !appPath.hasPrefix("/System/Library/CoreServices/") else { return nil }
        let bundle = Bundle(path: appPath)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? String(components[appIndex].dropLast(4))
        return (bundle?.bundleIdentifier ?? appPath, name, appPath)
    }
}
