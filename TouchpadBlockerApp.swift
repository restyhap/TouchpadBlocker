import Cocoa
import ServiceManagement

// MARK: - Configuration
let appName = "TouchpadBlocker"
let bundleIdentifier = "com.resty.touchpadblocker"

// MARK: - Touchpad Logic
class TouchpadManager {
    static let shared = TouchpadManager()
    
    private let defaultDelay: TimeInterval = 0.5
    
    var disableDelay: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: "BlockDelay")
            return val > 0 ? val : defaultDelay
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "BlockDelay")
        }
    }
    
    private var lastTypingTime: Date = Date.distantPast
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyMonitor: Any?
    
    var isEnabled = true {
        didSet {
            if isEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }
    
    private init() {}
    
    func startMonitoring() {
        if eventTap != nil { return }
        
        // Add NSEvent monitor as a backup for IME handling
        self.keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.updateLastTypingTime(source: "NSEvent")
        }
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.mouseMoved.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.scrollWheel.rawValue) |
                        (1 << CGEventType.leftMouseDragged.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)
        
        func callback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
            let manager = Unmanaged<TouchpadManager>.fromOpaque(refcon!).takeUnretainedValue()
            
            if type == .tapDisabledByTimeout {
                print("[DEBUG] Event tap disabled by timeout, re-enabling...")
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            
            return manager.handle(type: type, event: event)
        }
        
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: selfPointer
        ) else {
            print("Failed to create event tap. Accessibility permissions missing?")
            return
        }
        
        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Monitoring started")
    }
    
    func stopMonitoring() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            // CFMachPortInvalidate(eventTap) // Optional, depending on if we want to reuse
            self.eventTap = nil
        }
        
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        
        print("Monitoring stopped")
    }
    
    private func updateLastTypingTime(source: String) {
        lock.lock()
        lastTypingTime = Date()
        lock.unlock()
        print("[DEBUG] Typing detected via \(source) at \(lastTypingTime)")
    }
    
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown || type == .flagsChanged {
            updateLastTypingTime(source: type == .keyDown ? "CGEvent.KeyDown" : "CGEvent.FlagsChanged")
            return Unmanaged.passUnretained(event)
        }
        
        // Mouse events
        lock.lock()
        // Use a local copy of lastTypingTime to ensure consistency
        let currentLastTypingTime = lastTypingTime
        lock.unlock()
        
        let timeSinceTyping = Date().timeIntervalSince(currentLastTypingTime)
        
        if timeSinceTyping < disableDelay {
            print("[DEBUG] Blocking event type: \(type.rawValue), timeSinceTyping: \(timeSinceTyping)")
            return nil // Block event
        }
        
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Auto Start Manager
class AutoStartManager {
    static let shared = AutoStartManager()
    
    private var launchAgentURL: URL {
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let launchAgentsDir = libraryDir.appendingPathComponent("LaunchAgents")
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        return launchAgentsDir.appendingPathComponent("\(bundleIdentifier).plist")
    }
    
    var isAutoStartEnabled: Bool {
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }
    
    func toggleAutoStart() {
        if isAutoStartEnabled {
            disableAutoStart()
        } else {
            enableAutoStart()
        }
    }
    
    func enableAutoStart() {
        let appPath = Bundle.main.bundlePath
        let executablePath = Bundle.main.executablePath ?? appPath
        
        // Ensure we are pointing to the executable inside the .app if possible
        // For a proper .app, ProgramArguments usually points to the binary inside MacOS
        
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(bundleIdentifier)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """
        
        do {
            try plistContent.write(to: launchAgentURL, atomically: true, encoding: .utf8)
            print("Auto-start enabled. Plist written to \(launchAgentURL.path)")
        } catch {
            print("Failed to enable auto-start: \(error)")
        }
    }
    
    func disableAutoStart() {
        do {
            try FileManager.default.removeItem(at: launchAgentURL)
            print("Auto-start disabled.")
        } catch {
            print("Failed to disable auto-start: \(error)")
        }
    }
}

// MARK: - Auto Update Manager
struct VersionInfo: Codable {
    let version: String
    let download_url: String
    let release_notes: String
}

class UpdateManager {
    static let shared = UpdateManager()
    private let versionURL = URL(string: "https://gitee.com/restyhap/TouchpadBlocker/raw/main/version.json")!
    
    func checkForUpdates(silent: Bool = true) {
        URLSession.shared.dataTask(with: versionURL) { [weak self] data, _, error in
            guard let data = data, error == nil else {
                if !silent { self?.showError("Failed to check for updates.") }
                return
            }
            
            do {
                let info = try JSONDecoder().decode(VersionInfo.self, from: data)
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                
                if info.version.compare(currentVersion, options: .numeric) == .orderedDescending {
                    self?.downloadUpdate(info: info)
                } else if !silent {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Up to Date"
                        alert.informativeText = "You are using the latest version \(currentVersion)."
                        alert.runModal()
                    }
                }
            } catch {
                if !silent { self?.showError("Invalid version data.") }
            }
        }.resume()
    }
    
    private func downloadUpdate(info: VersionInfo) {
        guard let url = URL(string: info.download_url) else { return }
        
        URLSession.shared.downloadTask(with: url) { location, _, error in
            guard let location = location, error == nil else { return }
            
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            
            do {
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let zipPath = tempDir.appendingPathComponent("update.zip")
                try fileManager.moveItem(at: location, to: zipPath)
                
                // Unzip
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", zipPath.path, "-d", tempDir.path]
                try process.run()
                process.waitUntilExit()
                
                // Find .app
                let contents = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                if let appURL = contents.first(where: { $0.pathExtension == "app" }) {
                    DispatchQueue.main.async {
                        self.promptUpdate(newAppURL: appURL, info: info)
                    }
                }
            } catch {
                print("Update failed: \(error)")
            }
        }.resume()
    }
    
    private func promptUpdate(newAppURL: URL, info: VersionInfo) {
        let alert = NSAlert()
        alert.messageText = "New Version Available"
        alert.informativeText = "Version \(info.version) is ready. Restart to update?\n\n\(info.release_notes)"
        alert.addButton(withTitle: "Restart & Update")
        alert.addButton(withTitle: "Later")
        
        if alert.runModal() == .alertFirstButtonReturn {
            performUpdate(newAppURL: newAppURL)
        }
    }
    
    private func performUpdate(newAppURL: URL) {
        let currentAppURL = Bundle.main.bundleURL
        let script = "sleep 1; rm -rf \"\(currentAppURL.path)\"; mv \"\(newAppURL.path)\" \"\(currentAppURL.path)\"; open \"\(currentAppURL.path)\""
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        
        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            showError("Failed to launch update script.")
        }
    }
    
    private func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = message
            alert.runModal()
        }
    }
}

// MARK: - Preferences Window
class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private var inputField: NSTextField!
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.center()
        self.init(window: window)
        window.delegate = self
        setupUI()
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        // Label
        let label = NSTextField(labelWithString: "Block Delay (ms):")
        label.frame = NSRect(x: 40, y: 90, width: 120, height: 20)
        contentView.addSubview(label)
        
        // Input Field
        inputField = NSTextField(frame: NSRect(x: 160, y: 90, width: 80, height: 22))
        let currentDelayMs = Int(TouchpadManager.shared.disableDelay * 1000)
        inputField.stringValue = "\(currentDelayMs)"
        contentView.addSubview(inputField)
        
        // Save Button
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.frame = NSRect(x: 110, y: 40, width: 80, height: 24)
        contentView.addSubview(saveButton)
    }
    
    @objc private func saveClicked() {
        let valueStr = inputField.stringValue
        if let ms = Double(valueStr), ms > 0 {
            TouchpadManager.shared.disableDelay = ms / 1000.0
            window?.close()
        } else {
            let alert = NSAlert()
            alert.messageText = "Invalid Input"
            alert.informativeText = "Please enter a valid positive number for delay in milliseconds."
            alert.runModal()
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var preferencesWindowController: PreferencesWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup Status Bar Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // Use a simple unicode char or system image
            // "hand.raised.slash" is good but SF Symbols might not be available on older systems easily without image assets.
            // Let's use a text for simplicity or a drawing.
            button.title = "TB" 
            button.toolTip = "Touchpad Blocker"
        }
        
        updateMenu()
        
        // Start Blocking
        TouchpadManager.shared.startMonitoring()
        
        // Verify Accessibility Permissions
        checkPermissions()
        
        // Check for updates silently
        UpdateManager.shared.checkForUpdates(silent: true)
    }
    
    func checkPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !accessEnabled {
            print("Accessibility access not granted.")
            // We could show an alert here, but since it's a menu bar app, maybe just log or change icon state
            // In a real app, we should pop up a dialog.
            let alert = NSAlert()
            alert.messageText = "Permission Required"
            alert.informativeText = "Touchpad Blocker needs Accessibility permissions to work.\n\nPlease enable it in System Settings -> Privacy & Security -> Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                 if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    func updateMenu() {
        let menu = NSMenu()
        
        // Status Info
        let statusTitle = TouchpadManager.shared.isEnabled ? "Status: Active" : "Status: Paused"
        let statusItem = NSMenuItem(title: statusTitle, action: #selector(toggleStatus), keyEquivalent: "")
        statusItem.target = self
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        // Auto Start
        let autoStartItem = NSMenuItem(title: "Start at Login", action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStartItem.target = self
        autoStartItem.state = AutoStartManager.shared.isAutoStartEnabled ? .on : .off
        menu.addItem(autoStartItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        self.statusItem.menu = menu
        
        // Update Icon appearance if needed
        if let button = self.statusItem.button {
            button.alphaValue = TouchpadManager.shared.isEnabled ? 1.0 : 0.5
        }
    }
    
    @objc func toggleStatus() {
        TouchpadManager.shared.isEnabled.toggle()
        updateMenu()
    }
    
    @objc func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func toggleAutoStart() {
        AutoStartManager.shared.toggleAutoStart()
        updateMenu()
    }
    
    @objc func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(silent: false)
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }
}

// MARK: - Main Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
