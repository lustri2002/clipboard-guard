import Cocoa
import CoreFoundation
import UserNotifications

let agentID = "it.alessiolustri.clipboard-guard"
let watchedDomain = "com.apple.coreservices.useractivityd"
let watchedKey = "ClipboardSharingEnabled"

struct PreferenceState {
    let global: CFPropertyList?
    let host: CFPropertyList?

    static func enabled(_ value: CFPropertyList?) -> Bool {
        guard let value = value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    var healthy: Bool { Self.enabled(global) && (host == nil || Self.enabled(host)) }
    var summary: String { "standard=\(Self.describe(global)); host=\(Self.describe(host))" }

    static func describe(_ value: CFPropertyList?) -> String {
        guard let value = value else { return "missing" }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return (value as? NSNumber)?.boolValue == true ? "boolean true" : "boolean false"
        }
        return "non-boolean type"
    }
}

enum GuardError: Error { case synchronization, managedPreference, writeVerification }

final class PreferenceStore {
    let domain: CFString
    let key = watchedKey as CFString

    init(domain: String = watchedDomain) { self.domain = domain as CFString }

    func read() throws -> PreferenceState {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        else { throw GuardError.synchronization }
        return PreferenceState(
            global: CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            host: CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost))
    }

    func repair(_ before: PreferenceState) throws {
        if CFPreferencesAppValueIsForced(key, domain) { throw GuardError.managedPreference }
        if !PreferenceState.enabled(before.global) {
            CFPreferencesSetValue(key, kCFBooleanTrue, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        if before.host != nil && !PreferenceState.enabled(before.host) {
            CFPreferencesSetValue(key, kCFBooleanTrue, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        else { throw GuardError.synchronization }
        guard try read().healthy else { throw GuardError.writeVerification }
    }
}

// Exercises the actual CFPreferences API in an isolated disposable domain.
// Never changes the real useractivityd preferences or restarts its process.
func selfTest() throws {
    let domain = agentID + ".test." + UUID().uuidString
    let store = PreferenceStore(domain: domain)
    let unrelated = "UnrelatedSetting" as CFString
    func set(_ value: CFPropertyList?, host: CFString = kCFPreferencesAnyHost) {
        CFPreferencesSetValue(store.key, value, store.domain, kCFPreferencesCurrentUser, host)
        _ = CFPreferencesSynchronize(store.domain, kCFPreferencesCurrentUser, host)
    }
    defer {
        set(nil)
        set(nil, host: kCFPreferencesCurrentHost)
        CFPreferencesSetValue(unrelated, nil, store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        _ = CFPreferencesSynchronize(store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        print("PASS: \(label)")
    }
    var state = try store.read()
    try expect(!state.healthy, "missing preference requires repair")
    try store.repair(state)
    try expect(try store.read().healthy, "missing preference becomes boolean true")
    CFPreferencesSetValue(unrelated, "preserve-me" as CFString, store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    set(kCFBooleanFalse)
    state = try store.read()
    try expect(!state.healthy, "external false is detected after cache synchronization")
    try store.repair(state)
    try expect(try store.read().healthy, "external false is repaired")
    try expect(CFPreferencesCopyValue(unrelated, store.domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String == "preserve-me", "unrelated preferences survive repair")
    set("1" as CFString)
    try store.repair(try store.read())
    try expect(try store.read().healthy, "string 1 is normalized to boolean true")
    set(kCFBooleanFalse, host: kCFPreferencesCurrentHost)
    try expect(!(try store.read().healthy), "host-specific false override is detected")
    try store.repair(try store.read())
    state = try store.read()
    try expect(state.healthy && PreferenceState.enabled(state.host), "host override is repaired alongside standard preference")
}

final class GuardApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = PreferenceStore()
    let prefs = UserDefaults.standard
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clipboard Guard", isDirectory: true)
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClipboardGuard", isDirectory: true)
    var statusItem: NSStatusItem!
    let stateItem = NSMenuItem(title: "Starting monitoring…", action: nil, keyEquivalent: "")
    let notificationItem = NSMenuItem(title: "Notifications: checking…", action: nil, keyEquivalent: "")
    var timer: Timer?
    var watcher: DispatchSourceFileSystemObject?
    var watchedInode: UInt64?
    var pendingCheck: DispatchWorkItem?
    var lastCheck = Date.distantPast
    var lastStatusWrite = Date.distantPast
    var lastRestart = Date.distantPast
    var lastErrorLog = Date.distantPast
    var restartPending = false
    var repairs = 0
    var healthy = false
    var checking = false
    var notificationStatus = "unknown"
    var lastRepair: Date?
    var lastFailure: String?

    var logFile: URL { logs.appendingPathComponent("guard.log") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.notificationStatus = granted ? "authorized" : "denied"
                self.notificationItem.title = granted ? "Notifications: allowed" : "Notifications: enable in System Settings"
                self.log("notifications: \(self.notificationStatus)\(error == nil ? "" : "; authorization error")")
                self.writeStatus(force: true)
            }
        }
        log("started pid=\(ProcessInfo.processInfo.processIdentifier); interval=2s; watches only \(watchedKey)")
        attachWatcher()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.attachWatcher()
            self?.check()
        }
        timer?.tolerance = 0.25
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard Guard")
        statusItem.button?.toolTip = "Clipboard Guard — Universal Clipboard monitoring"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Clipboard Guard", action: nil, keyEquivalent: ""))
        menu.addItem(stateItem)
        menu.addItem(notificationItem)
        menu.addItem(.separator())
        for (title, action) in [("Check Now", #selector(checkNow)),
                                ("Send Test Notification", #selector(testNotification)),
                                ("Open Log", #selector(openLog)),
                                ("About", #selector(showInfo))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    // File events give fast detection. The timer covers cfprefsd buffering,
    // atomic replacement, missing files and events missed during sleep.
    func attachWatcher() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(watchedDomain).plist").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { return }
        if watcher != nil && watchedInode == inode { return }
        watcher?.cancel()
        watcher = nil
        watchedInode = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            self?.pendingCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.attachWatcher(); self?.check() }
            self?.pendingCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        watcher = source
        watchedInode = inode
        source.resume()
    }

    @objc func woke() { attachWatcher(); check() }
    @objc func checkNow() { check(); refreshNotificationStatus() }

    func check() {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        lastCheck = Date()
        do {
            let before = try store.read()
            if !before.healthy {
                try store.repair(before)
                repairs += 1
                lastRepair = Date()
                log("repaired \(watchedKey): \(before.summary) -> boolean true")
                restartPending = true
                notifyCorrection()
            }
            healthy = true
            lastFailure = nil
            if restartPending && Date().timeIntervalSince(lastRestart) >= 60 {
                restartActivityService()
            }
            stateItem.title = "Active · clipboard sharing enabled"
            writeStatus(force: !before.healthy)
        } catch {
            healthy = false
            lastFailure = String(describing: error)
            stateItem.title = "Warning · repair failed"
            if Date().timeIntervalSince(lastErrorLog) >= 60 {
                log("check/repair failed: \(String(describing: error))")
                lastErrorLog = Date()
            }
            notify(title: "Universal Clipboard: action required", body: "Could not enable clipboard sharing on this Mac. Open Clipboard Guard in the menu bar for details.", cooldownKey: "lastFailureNotification")
            writeStatus(force: true)
        }
    }

    func restartActivityService() {
        lastRestart = Date()
        restartPending = false
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["-u", NSUserName(), "useractivityd"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            DispatchQueue.main.async {
                self.log("useractivityd reload exit=\(process.terminationStatus) (1 may mean service not running)")
            }
        }
        do { try task.run() }
        catch { restartPending = true; log("cannot reload useractivityd: \(error.localizedDescription)") }
    }

    func notifyCorrection() {
        notify(title: "Universal Clipboard re-enabled", body: "Clipboard sharing is enabled again on your Mac. If copy and paste still does not work, restart your iPhone.", cooldownKey: "lastRepairNotification")
    }

    func notify(title: String, body: String, cooldownKey: String?) {
        if let key = cooldownKey, let last = prefs.object(forKey: key) as? Date,
           Date().timeIntervalSince(last) < 900 { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async { self.log("notification not delivered: permission absent") }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: cooldownKey ?? "test-\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request) { error in
                DispatchQueue.main.async {
                    if let error = error { self.log("notification scheduling failed: \(error.localizedDescription)") }
                    else {
                        if let key = cooldownKey { self.prefs.set(Date(), forKey: key) }
                        self.log("notification scheduled: \(title)")
                    }
                }
            }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self.notificationStatus = granted ? "authorized" : "denied"
                self.notificationItem.title = granted ? "Notifications: allowed" : "Notifications: enable in System Settings"
                self.writeStatus(force: true)
            }
        }
    }

    @objc func testNotification() {
        refreshNotificationStatus()
        notify(title: "Clipboard Guard is running", body: "ClipboardSharingEnabled is checked every 2 seconds. You will be notified if it needs to be re-enabled.", cooldownKey: nil)
    }
    @objc func openLog() { NSWorkspace.shared.open(logFile) }
    @objc func showInfo() {
        let alert = NSAlert()
        alert.messageText = "Clipboard Guard"
        alert.informativeText = "Monitors ClipboardSharingEnabled using file events and a check every 2 seconds. Restores boolean true and reloads useractivityd only when needed.\n\nRuns during your Mac session and starts at login. Does not read clipboard contents and cannot directly detect an iPhone-side failure. Repair notifications are limited to one every 15 minutes.\n\nLog: \(logFile.path)"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func log(_ message: String) {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? NSNumber, size.intValue >= 524_288 {
            let old = logs.appendingPathComponent("guard.previous.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logFile, to: old)
        }
        if !fm.fileExists(atPath: logFile.path) { fm.createFile(atPath: logFile.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logFile),
              let data = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n".data(using: .utf8) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch { }
    }

    func writeStatus(force: Bool) {
        guard force || Date().timeIntervalSince(lastStatusWrite) >= 60 else { return }
        lastStatusWrite = Date()
        let formatter = ISO8601DateFormatter()
        var status: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                   "healthy": healthy, "lastCheck": formatter.string(from: lastCheck),
                                   "repairsThisRun": repairs, "intervalSeconds": 2,
                                   "notifications": notificationStatus, "domain": watchedDomain, "key": watchedKey]
        if let date = lastRepair { status["lastRepair"] = formatter.string(from: date) }
        if let failure = lastFailure { status["lastFailure"] = failure }
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: support.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

if CommandLine.arguments.contains("--self-test") {
    do { try selfTest(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}

if CommandLine.arguments.contains("--notification-status") {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        let result: [String: Any] = [
            "authorizationStatus": settings.authorizationStatus.rawValue,
            "alertSetting": settings.alertSetting.rawValue,
            "alertStyle": settings.alertStyle.rawValue
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print(json) }
        exit(0)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
        fputs("Notification status query timed out\n", stderr)
        exit(1)
    }
    dispatchMain()
}

let application = NSApplication.shared
let delegate = GuardApp()
application.delegate = delegate
application.run()
