import SwiftUI

/// Settings window delegate (the app delegate owns the NSWindow).
protocol SettingsViewDelegate: AnyObject {
    func settingsViewRequestsClose()
}

/// The settings window: tabs for pack, force/sensor, audio and general.
struct SettingsView: View {
    @ObservedObject var state: AppState
    weak var delegate: SettingsViewDelegate?

    var body: some View {
        TabView {
            PackTab(state: state)
                .tabItem { Label("Sound pack", systemImage: "square.stack.3d.up") }
            ForceTab(state: state)
                .tabItem { Label("Force", systemImage: "waveform.path.ecg") }
            AudioTab(state: state)
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            GeneralTab(state: state)
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

// MARK: - sound pack

private struct PackTab: View {
    @ObservedObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Sound pack") {
                    if state.packs.isEmpty {
                        Text("No packs found. Run `make packs` and rebuild.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(state.packs) { pack in
                                PackCard(pack: pack,
                                         isSelected: pack.id == state.selectedPackID)
                                    .onTapGesture { state.selectPack(id: pack.id) }
                            }
                        }
                    }
                }

                GroupBox("Preview the selected pack") {
                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { tier in
                            Button(AppState.tierLabels[tier]) { state.testPlay(tier: tier) }
                                .buttonStyle(.bordered)
                        }
                        Spacer()
                        Text("\(state.selectedPackID)").foregroundStyle(.secondary).font(.footnote.monospaced())
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(16)
        }
    }
}

private struct PackCard: View {
    let pack: PackInfo
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(pack.name).font(.headline).lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            Text(pack.familyLabel)
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: Capsule())
            Text("\(pack.clipCount) clips").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - force / sensor

private struct ForceTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sensorCard
                graphCard
                calibrationCard
                sensitivityCard
            }
            .padding(16)
        }
    }

    private var sensorCard: some View {
        GroupBox("Accelerometer") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    StatusPill(title: state.sensorAvailable ? "SPU present" : "No SPU sensor",
                               ok: state.sensorAvailable,
                               symbol: state.sensorAvailable ? "cpu" : "exclamationmark.triangle")
                    StatusPill(title: state.sensorRunning ? "Streaming" : "Idle",
                               ok: state.sensorRunning,
                               symbol: state.sensorRunning ? "dot.radiowaves.right" : "pause")
                    StatusPill(title: String(format: "%.0f Hz", state.sensorRateHz),
                               ok: state.sensorRateHz > 100,
                               symbol: "speedometer")
                    StatusPill(title: String(format: "%.2f ms", state.audioLatency),
                               ok: state.audioLatency < 12,
                               symbol: "timer")
                }
                Text("Force is measured from the chassis vibration your keystrokes make in the MacBook's aluminium. " +
                     "Sensitivity shifts the boundaries between soft, medium, hard and slam.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text("Noise floor: \(String(format: "%.4f", state.telemetry.noiseFloor)) g")
                    Spacer()
                    Text("Last impact: \(String(format: "%.3f", state.telemetry.lastMagnitude)) g")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var graphCard: some View {
        GroupBox("Live force signal") {
            VStack(alignment: .leading, spacing: 6) {
                ActivityGraph(history: state.telemetry.magnitudeHistory,
                              noiseFloor: state.telemetry.noiseFloor,
                              impacts: state.telemetry.recentImpacts)
                    .frame(height: 92)
                HStack {
                    Text("Impacts detected: \(state.telemetry.impactCount)")
                    Spacer()
                    Text("recent scores: " + state.telemetry.recentImpacts.map {
                        String(format: "%.2f", $0)
                    }.joined(separator: "  "))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    Text("Keystrokes played: \(state.keysPlayed)")
                    Spacer()
                    Text("last: \(AppState.tierLabels[min(3, max(0, state.lastTier))]) " +
                         "\(state.lastFromSensor ? "(measured)" : "(predicted)")")
                }
                .font(.caption)
                .foregroundStyle(state.lastFromSensor ? Color.secondary : Color.orange)
            }
            .padding(.vertical, 4)
        }
    }

    private var sensitivityCard: some View {
        GroupBox("Sensitivity") {
            VStack(alignment: .leading, spacing: 8) {
                Slider(value: Binding(get: { state.sensitivity },
                                      set: { state.setSensitivity($0) }),
                       in: 0.4...2.5, step: 0.05) {
                    Text("Force scale")
                }
                HStack {
                    Text("Gentle").font(.caption)
                    Spacer()
                    Text(String(format: "%.2fx", state.sensitivity)).font(.caption.monospacedDigit())
                    Spacer()
                    Text("Energetic").font(.caption)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var calibrationCard: some View {
        GroupBox("Calibration") {
            VStack(alignment: .leading, spacing: 8) {
                if state.isCalibrating {
                    ProgressView(value: min(1, state.telemetry.calibrationProgress))
                    Text("Type normally… samples: \(state.telemetry.calibrationSamples)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(state.calibrationMessage ?? "Not calibrated. Use the defaults, or type for 8 seconds to teach Keystrike your touch.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(state.isCalibrating ? "Calibrating…" : "Start calibration") {
                        state.startCalibration()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { state.finishCalibration() }
                    }
                    .disabled(state.isCalibrating || !state.sensorRunning)
                    Button("Reset") { state.resetCalibration() }
                    Spacer()
                    Text("soft ≤ \(String(format: "%.3f", Settings.softCeiling)) g · slam ≥ \(String(format: "%.3f", Settings.slamFloor)) g")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Small status chip.
private struct StatusPill: View {
    let title: String
    let ok: Bool
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((ok ? Color.green : Color.orange).opacity(0.18), in: Capsule())
            .foregroundStyle(ok ? Color.green : Color.orange)
    }
}

// MARK: - audio

private struct AudioTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        Slider(value: Binding(get: { state.volume }, set: { state.volume = $0 }),
                               in: 0...1)
                        HStack {
                            Text("Volume").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(state.volume * 100))%").monospacedDigit()
                        }
                        .font(.caption)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                            GridRow {
                                Text("Sample rate").foregroundStyle(.secondary)
                                Text("\(state.audioRate) Hz").monospacedDigit()
                            }
                            GridRow {
                                Text("IO buffer").foregroundStyle(.secondary)
                                Text("\(state.audioBuffer) frames").monospacedDigit()
                            }
                            GridRow {
                                Text("Round-trip latency").foregroundStyle(.secondary)
                                Text(String(format: "%.2f ms", state.audioLatency)).monospacedDigit()
                            }
                            GridRow {
                                Text("Render callbacks").foregroundStyle(.secondary)
                                Text("\(state.renderCalls)").monospacedDigit()
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Test playback") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ForEach(0..<4, id: \.self) { tier in
                                Button(AppState.tierLabels[tier]) { state.testPlay(tier: tier) }
                            }
                        }
                        Button("Simulate typing (3 s)") { state.simulateTyping(seconds: 3) }
                            .disabled(!state.isEnabled)
                        Toggle("Release sounds", isOn: Binding(
                            get: { state.releaseSounds },
                            set: { state.releaseSounds = $0; Settings.releaseSounds = $0 }))
                        Toggle("Pause the audio engine when idle", isOn: Binding(
                            get: { state.idlePause },
                            set: { state.idlePause = $0; Settings.idlePause = $0 }))
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - general

private struct GeneralTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Keystrike") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Play keystroke sounds", isOn: Binding(
                            get: { state.isEnabled },
                            set: { state.isEnabled ? ($0 ? nil : state.disable()) : state.enable() }))
                        HStack(spacing: 12) {
                            StatusPill(title: KeyboardTap.hasPermission ? "Accessibility granted" : "Needs Accessibility",
                                       ok: KeyboardTap.hasPermission,
                                       symbol: KeyboardTap.hasPermission ? "lock.open" : "lock")
                            Button("Open System Settings…") { KeyboardTap.openAccessibilitySettings() }
                            Button("Re-check") { state.ensureTap() }
                        }
                        Text("Keystrike only reads key codes: it never sees or stores what you type. " +
                             "Accessibility permission is how macOS lets an app observe key events at all.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Typing force") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Vary force when no accelerometer reading is available", isOn: Binding(
                            get: { state.fallbackForce },
                            set: { state.fallbackForce = $0; Settings.fallbackForce = $0 }))
                        Text("With this on, machines without the SPU sensor still get soft-to-slam variation " +
                             "estimated from typing rhythm. With it off, those keystrokes land on medium.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Launch at login", isOn: Binding(
                            get: { Settings.launchAtLogin },
                            set: { newValue in
                                Settings.launchAtLogin = newValue
                                LaunchAtLogin.setEnabled(newValue) { error in
                                    if let error { Log.error("launch at login: \(error)") }
                                }
                            }))
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keystrike 1.0").font(.headline)
                        Text("Force-sensitive mechanical keyboard sounds for Apple Silicon MacBooks.")
                            .font(.callout)
                        Text("Switch recordings: Mechvibes/ClickClack (MIT). Sound engine in C; " +
                             "accelerometer via the undocumented AppleSPU HID interface.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Open log") {
                                let url = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent("Library/Logs/Keystrike")
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(16)
        }
    }
}
