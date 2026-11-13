import AppKit
import SwiftUI

/// Menu bar app delegate. Builds the status item, the menu, and the settings
/// window. This is a UIElement (agent) app: no Dock icon, no main window unless
/// the user opens settings.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var keyboardWindow: NSWindow?
    private let app = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        app.presentKeyboard = { [weak self] in self?.showKeyboard() }
        buildStatusItem()
        if ProcessInfo.processInfo.environment["THOCKY_SHOW_KEYBOARD"] != nil {
            /* used by build scripts and demos: open the keyboard with the app */
            showKeyboard()
        }
        Log.info("thocky started (enabled=\(app.isEnabled), packs=\(app.packs.count))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("thocky shutting down")
        app.shutDown()
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
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Thocky")
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
        volItem.view = VolumeRow(value: app.volume) { [weak self] v in
            self?.app.volume = v
        }
        menu.addItem(volItem)

        menu.addItem(.separator())
        menu.addItem(menuItem("Test sound…", #selector(testSound(_:))))
        menu.addItem(menuItem(app.isCalibrating ? "Calibrating…" : "Calibrate force sensor…",
                              #selector(startCalibration)))
        menu.addItem(menuItem("Show keyboard", #selector(showKeyboard), key: "k"))
        menu.addItem(.separator())
        /* macOS builds the tap for an untrusted process and then drops every
           event in silence, so a live tap object says nothing about whether the
           app can hear. Judge by trust, not by the tap. */
        if app.tapDeaf || !KeyboardTap.hasPermission {
            let text = app.tapDeaf
                ? "⚠️ No key events — Accessibility is granted to a different Thocky. Click to fix"
                : "⚠️ Grant Accessibility — the keyboard tap cannot hear keys yet"
            let warn = NSMenuItem(title: text, action: #selector(requestAccessibility), keyEquivalent: "")
            warn.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.foregroundColor: NSColor.systemRed])
            warn.target = self
            menu.addItem(warn)
            menu.addItem(menuItem("Open System Settings…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(menuItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(menuItem("Open log", #selector(openLog)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Thocky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
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
            let view = SettingsView(state: app)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 720, height: 560))
            window.minSize = NSSize(width: 640, height: 480)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showKeyboard() {
        if keyboardWindow == nil {
            let view = KeyboardView(state: app)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "Keyboard"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(srgbRed: 0.07, green: 0.075, blue: 0.09, alpha: 1)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 980, height: 560))
            window.minSize = NSSize(width: 760, height: 460)
            window.center()
            keyboardWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        keyboardWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAccessibilitySettings() {
        KeyboardTap.openAccessibilitySettings()
        rebuildMenu()
    }

    @objc private func openLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Thocky")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}

/// A volume slider row suitable for embedding in a menu.
private final class VolumeRow: NSView {
    private let slider = NSSlider()
    init(value: Double, onChange: @escaping (Double) -> Void) {
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

