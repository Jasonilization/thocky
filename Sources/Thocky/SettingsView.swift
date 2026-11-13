import SwiftUI

/// The settings window: sound, force, audio, and general.
struct SettingsView: View {
    @ObservedObject var state: AppState

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
                recentCard
                sensitivityCard
                calibrationCard
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
                Text("Force comes from the vibration a keystroke makes in the aluminium.")
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

    /// The last few keystrokes with what the app decided about each: the point
    /// is that every sound you hear has an explanation you can check.
    private var recentCard: some View {
        GroupBox("Recent keystrokes") {
            VStack(alignment: .leading, spacing: 3) {
                if state.recentHits.isEmpty {
                    Text("Type, and each keystroke shows up here with the force it measured.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(state.recentHits.prefix(8)) { hit in
                        HStack(spacing: 8) {
                            Text(hit.label)
                                .font(.caption.monospaced().bold())
                                .frame(width: 64, alignment: .leading)
                            Text(hit.tierLabel)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(tierColor(hit.tier).opacity(0.22), in: Capsule())
                                .foregroundStyle(tierColor(hit.tier))
                                .frame(width: 58, alignment: .leading)
                            Text(String(format: "score %.2f  peak %.3f g", hit.score, hit.peakG))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(hit.measured ? "measured" : "predicted")
                                .font(.caption2)
                                .foregroundStyle(hit.measured ? Color.green : Color.orange)
                            Text(String(format: "pan %+.2f", hit.pan))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func tierColor(_ tier: Int) -> Color {
        switch tier {
        case 0: return Color(red: 0.35, green: 0.70, blue: 1.0)
        case 1: return Color(red: 0.35, green: 0.90, blue: 0.65)
        case 2: return Color(red: 1.0, green: 0.78, blue: 0.35)
        default: return Color(red: 1.0, green: 0.42, blue: 0.42)
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
                    Text(state.calibrationMessage ?? "Defaults are in use. Type for 8 seconds to match your touch.")
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
                GroupBox("Thocky") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Play keystroke sounds", isOn: Binding(
                            get: { state.isEnabled },
                            set: { enabled in
                                if enabled { state.enable() } else { state.disable() }
                            }))
                        HStack(spacing: 12) {
                            Button("Show keyboard") { state.presentKeyboard?() }
                            Spacer()
                        }
                        HStack(spacing: 12) {
                            StatusPill(title: KeyboardTap.hasPermission ? "Accessibility granted" : "Needs Accessibility",
                                       ok: KeyboardTap.hasPermission,
                                       symbol: KeyboardTap.hasPermission ? "lock.open" : "lock")
                            Button("Open System Settings…") { KeyboardTap.openAccessibilitySettings() }
                            Button("Re-check") { state.ensureTap() }
                        }
                        if state.tapDeaf {
                            /* the trap: macOS builds the tap and then throws the
                               events away, so the app looks healthy and is silent */
                            Text("macOS created the keyboard tap but is dropping every key event. " +
                                 "The accelerometer is hearing your typing while the tap is not, " +
                                 "which means Accessibility is granted to a different copy of Thocky. " +
                                 "Open System Settings and toggle **every** Thocky entry on.")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Thocky reads key codes only. It never sees or stores what you type.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Typing force") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Vary force when no accelerometer reading is available", isOn: Binding(
                            get: { state.fallbackForce },
                            set: { state.fallbackForce = $0; Settings.fallbackForce = $0 }))
                        Text("Without the accelerometer, rhythm estimates soft through slam. Off keeps those keystrokes at medium.")
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
                        Text("Thocky 1.0").font(.headline)
                        Text("Force-sensitive mechanical keyboard sounds for Apple Silicon MacBooks.")
                            .font(.callout)
                        Text("Switch recordings: Mechvibes/ClickClack (MIT). Sound engine in C; " +
                             "accelerometer via the undocumented AppleSPU HID interface.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Open log") {
                                let url = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent("Library/Logs/Thocky")
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
