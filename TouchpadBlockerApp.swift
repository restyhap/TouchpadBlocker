import Cocoa
import ServiceManagement

// MARK: - Configuration
let appName = "TouchpadBlocker"
let bundleIdentifier = "com.resty.touchpadblocker"

// MARK: - Touchpad Logic
class TouchpadManager {
    static let shared = TouchpadManager()
    
    private let disableDelay: TimeInterval = 0.5
    private var lastTypingTime: Date = Date.distantPast
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
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
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.mouseMoved.rawValue) |
                        (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.scrollWheel.rawValue) |
                        (1 << CGEventType.leftMouseDragged.rawValue)
        
        func callback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
            let manager = Unmanaged<TouchpadManager>.fromOpaque(refcon!).takeUnretainedValue()
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
        print("Monitoring stopped")
    }
    
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            lock.lock()
            lastTypingTime = Date()
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        
        // Mouse events
        lock.lock()
        let timeSinceTyping = Date().timeIntervalSince(lastTypingTime)
        lock.unlock()
        
        if timeSinceTyping < disableDelay {
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

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    
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
        
        // Auto Start
        let autoStartItem = NSMenuItem(title: "Start at Login", action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStartItem.target = self
        autoStartItem.state = AutoStartManager.shared.isAutoStartEnabled ? .on : .off
        menu.addItem(autoStartItem)
        
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
    
    @objc func toggleAutoStart() {
        AutoStartManager.shared.toggleAutoStart()
        updateMenu()
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
