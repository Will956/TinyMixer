import SwiftUI

struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App volumes").font(.headline)

            if model.apps.isEmpty {
                Text("No app is using audio right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if model.apps.count > 8 {
                ScrollView { rows.padding(.trailing, 8) }.frame(height: 400)
            } else {
                rows
            }

            if let error = model.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Open audio recording settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Divider()

            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button("Reset all") { model.resetAll() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var rows: some View {
        VStack(spacing: 10) {
            ForEach(model.apps) { app in
                AppVolumeRow(app: app, model: model)
            }
        }
    }
}

private struct AppVolumeRow: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel

    var body: some View {
        let muted = model.isMuted(app)
        let volume = model.volume(for: app)

        HStack(spacing: 10) {
            Image(nsImage: model.icon(for: app))
                .resizable()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.name).lineLimit(1).truncationMode(.tail)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Playing")
                    }
                    Spacer()
                    Text(muted ? "Muted" : "\(Int((volume * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Button { model.toggleMute(app) } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(muted ? "Unmute" : "Mute")

                    Slider(value: Binding(get: { volume }, set: { model.setVolume($0, for: app) }), in: 0...1)
                        .controlSize(.small)
                        .disabled(muted)
                }
            }
        }
    }
}
