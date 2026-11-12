import AppKit
import SwiftUI

/// Menu bar app delegate. Builds the status item, the menu, and the settings
/// window. This is a UIElement (agent) app: no Dock icon, no main window unless
/// the user opens settings.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let app = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        Log.info("keystrike started (enabled=\(app.isEnabled), packs=\(app.packs.count))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("keystrike shutting down")
        app.disable()
        app.engine.shutdown()
    }

    // MARK: status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = app.isEnabled ? "waveform" : "waveform.badge.exclamationmark"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Keystrike")
        button.contentTintColor = app.isEnabled ? nil : NSColor.secondaryLabelColor
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        updateIcon()

        let enabled = NSMenuItem(title: app.isEnabled ? "Disable sound" : "Enable sound",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        menu.addItem(enabled)
        menu.addItem(.separator())

        // pack submenu
        let packItem = NSMenuItem(title: "Sound pack", action: nil, keyEquivalent: "")
        let packMenu = NSMenu()
        for pack in app.packs {
            let item = NSMenuItem(title: pack.name, action: #selector(selectPack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pack.id
            item.state = pack.id == app.selectedPackID ? .on : .off
            packMenu.addItem(item)
        }
        packItem.submenu = packMenu
        menu.addItem(packItem)

        // sensitivity
        let sensItem = NSMenuItem(title: "Force sensitivity", action: nil, keyEquivalent: "")
        let sensMenu = NSMenu()
        for (label, value) in [("Gentle", 0.6), ("Balanced", 1.0), ("Energetic", 1.6)] {
            let item = NSMenuItem(title: label, action: #selector(selectSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(app.sensitivity - value) < 0.01 ? .on : .off
            sensMenu.addItem(item)
        }
        sensItem.submenu = sensMenu
        menu.addItem(sensItem)

        // volume
        let volItem = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
        volItem.view = VolumeRow(engine: app.engine, value: app.volume) { [weak self] v in
            self?.app.volume = v
        }
        menu.addItem(volItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Test sound…", action: #selector(testSound), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: app.isCalibrating ? "Calibrating…" : "Calibrate force sensor…",
                                action: #selector(startCalibration), keyEquivalent: ""))
        menu.addItem(.separator())
        if !app.tapAuthorized {
            let perm = NSMenuItem(title: "Grant Accessibility access…", action: #selector(requestAccessibility), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Keystrike", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: actions

    @objc private func toggleEnabled() {
        app.toggleEnabled()
        rebuildMenu()
    }

    @objc private func selectPack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        app.selectPack(id: id)
        rebuildMenu()
    }

    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        app.setSensitivity(value)
    }

    @objc private func testSound(_ sender: NSMenuItem) {
        app.ensurePack()
        app.simulateTyping(seconds: 3)
    }

    @objc private func startCalibration() {
        app.startCalibration()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) { [weak self] in
            self?.app.finishCalibration()
            self?.rebuildMenu()
        }
    }

    @objc private func requestAccessibility() {
        app.requestAccessibility()
        rebuildMenu()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(state: app, delegate: self)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "Keystrike"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 680, height: 520))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func settingsViewRequestsClose() {
        settingsWindow?.performClose(nil)
        settingsWindow = nil
    }

    @objc private func openLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Keystrike")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}

extension AppDelegate: SettingsViewDelegate {}

/// A volume slider row suitable for embedding in a menu.
private final class VolumeRow: NSView {
    private let slider = NSSlider()
    init(engine: AudioEngine, value: Double, onChange: @escaping (Double) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        slider.isContinuous = true
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = value * 100
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        onSlider = onChange
    }

    private var onSlider: ((Double) -> Void)?
    @objc private func changed() { onSlider?(slider.doubleValue / 100) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

