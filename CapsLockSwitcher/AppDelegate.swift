import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import OSLog

// MARK: - Logger Categories

extension Logger {
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.doasync.CapsLockSwitcher"
    static let app = Logger(subsystem: subsystem, category: "Application")
    static let state = Logger(subsystem: subsystem, category: "StateManagement")
    static let hotKey = Logger(subsystem: subsystem, category: "HotKey")
    static let hid = Logger(subsystem: subsystem, category: "HIDUtil")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
}

// MARK: - Carbon Hot Key Callback
//
// Caps Lock is remapped (via hidutil) to the LANG1 key, which macOS delivers as kVK_JIS_Kana.
// We grab that key with a Carbon hot key instead of a CGEventTap because:
//  * WindowServer keeps dispatching hot keys while Secure Event Input is on (password fields,
//    or an app that leaked Secure Input). Event taps go deaf in that state, which made Caps Lock
//    do nothing at all.
//  * There is no tap for macOS to disable on timeout, so nothing needs re-enabling.
//  * Hot keys need no Accessibility / Input Monitoring permission.
//  * The key is consumed by WindowServer, so LANG1 never reaches the focused app.

private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == AppDelegate.hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    delegate.handleHotKey(id: hotKeyID.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
    return noErr
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Constants & Core Properties

    private enum PrefKeys {
        static let selectedSourceID1 = "selectedSourceID1"
        static let selectedSourceID2 = "selectedSourceID2"
        static let hasShownWelcome = "hasShownWelcome"
        static let capsLockViaShift = "capsLockViaShift"
        static let capsLockViaCommand = "capsLockViaCommand"
        static let capsLockViaHold = "capsLockViaHold"
        static let didMigrateSandboxPrefs = "didMigrateSandboxPrefs"
    }

    fileprivate static let hotKeySignature: OSType = 0x434C_5357 // 'CLSW'

    private enum HotKeyID: UInt32 {
        case switchLayout = 1         // Caps Lock
        case capsLockWithShift = 2    // Shift + Caps Lock
        case capsLockWithCommand = 3  // Command + Caps Lock (either Command key)
    }

    private let hidCapsLockUsage = 0x700000039
    private let hidLangKeyUsage = 0x700000090 // Keyboard LANG1, arrives as kVK_JIS_Kana
    private let triggerKeyCode = UInt32(kVK_JIS_Kana)
    private let holdThreshold: TimeInterval = 0.4
    private let remapCheckInterval: TimeInterval = 30

    fileprivate enum AppOperationalState: String, CustomStringConvertible {
        case configuring = "Configuring"
        case active = "Active"

        var description: String { self.rawValue }
    }

    private var statusItem: NSStatusItem?
    private var appMenu: NSMenu?
    private var statusMenuItem: NSMenuItem?

    fileprivate struct AppState {
        var selectedSourceID1: String? = nil
        var selectedSourceID2: String? = nil
        var targetSource1Ref: TISInputSource? = nil
        var targetSource2Ref: TISInputSource? = nil
        var availableSelectionCount: Int = 0
        var allSelectableSources: [TISInputSource] = []
        var menuItemToSourceMap: [NSMenuItem: TISInputSource] = [:]
        var currentOperationalState: AppOperationalState = .configuring
        var isHidRemappingApplied: Bool = false
        var hotKeyHandler: EventHandlerRef? = nil
        var switchHotKey: EventHotKeyRef? = nil
        var capsLockHotKeys: [UInt32: EventHotKeyRef] = [:]
        var hotKeyError: OSStatus? = nil
    }
    fileprivate var state = AppState()

    private let capsLockController = CapsLockController()

    // Hold-to-Caps-Lock tracking
    private var triggerDownAt: Date?
    private var holdWorkItem: DispatchWorkItem?
    // Modifier + Caps Lock hot keys currently held, so key repeat doesn't toggle uppercase back and forth
    private var capsLockHotKeysDownAt: [UInt32: Date] = [:]

    private var remapCheckTimer: Timer?

    private var capsLockViaShift: Bool {
        get { UserDefaults.standard.object(forKey: PrefKeys.capsLockViaShift) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKeys.capsLockViaShift) }
    }

    private var capsLockViaCommand: Bool {
        get { UserDefaults.standard.object(forKey: PrefKeys.capsLockViaCommand) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKeys.capsLockViaCommand) }
    }

    private var capsLockViaHold: Bool {
        get { UserDefaults.standard.object(forKey: PrefKeys.capsLockViaHold) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: PrefKeys.capsLockViaHold) }
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Logger.app.info("CapsLockSwitcher (HID Remap + Hot Key): Did Finish Launching")

        migrateSandboxPreferencesIfNeeded()
        state.selectedSourceID1 = UserDefaults.standard.string(forKey: PrefKeys.selectedSourceID1)
        state.selectedSourceID2 = UserDefaults.standard.string(forKey: PrefKeys.selectedSourceID2)

        // A previous run may have crashed with Caps Lock still remapped. Start from a clean slate.
        runHidutilSync(enable: false, context: "Launch Initial Reset")

        installHotKeyHandler()
        observeSystemEvents()
        determineStateAndSetupUI(context: "Launch")
        setupRemapCheckTimer()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        Logger.app.info("CapsLockSwitcher: Will Terminate")
        remapCheckTimer?.invalidate()
        remapCheckTimer = nil

        // Must be synchronous: an async revert can lose the race with process exit,
        // leaving Caps Lock mapped to LANG1 with nobody listening (a dead key).
        runHidutilSync(enable: false, context: "Terminate")
        unregisterHotKeys()

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - Preferences Migration

    /// Versions up to 1.2 were sandboxed and kept their preferences inside the app container.
    /// Copy the layout selection over once so upgrading doesn't require reconfiguring.
    private func migrateSandboxPreferencesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PrefKeys.didMigrateSandboxPrefs) else { return }
        defaults.set(true, forKey: PrefKeys.didMigrateSandboxPrefs)

        guard defaults.string(forKey: PrefKeys.selectedSourceID1) == nil,
              defaults.string(forKey: PrefKeys.selectedSourceID2) == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return }

        let containerPrefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
        guard let old = NSDictionary(contentsOf: containerPrefs) as? [String: Any] else { return }

        for key in [PrefKeys.selectedSourceID1, PrefKeys.selectedSourceID2, PrefKeys.hasShownWelcome] {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
        Logger.settings.info("Migrated preferences from sandbox container.")
    }

    // MARK: - System Event Observation

    private func observeSystemEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceCenter.addObserver(self, selector: #selector(systemDidResume(_:)), name: name, object: nil)
        }

        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(self, selector: #selector(systemDidResume(_:)), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        distributedCenter.addObserver(
            self,
            selector: #selector(inputSourcesChanged(_:)),
            name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil
        )
    }

    /// After sleep, unlock or a user switch the HID stack may have been reset; make sure the remap is still there.
    @objc private func systemDidResume(_ notification: Notification) {
        Logger.hid.info("System resumed (\(notification.name.rawValue, privacy: .public)). Verifying remap shortly.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.verifyHidRemapping(context: notification.name.rawValue)
        }
    }

    @objc private func inputSourcesChanged(_ notification: Notification) {
        Logger.settings.info("Enabled input sources changed, re-determining state.")
        determineStateAndSetupUI(context: "InputSourcesChanged")
    }

    private func setupRemapCheckTimer() {
        guard remapCheckTimer == nil else { return }
        let timer = Timer(timeInterval: remapCheckInterval, repeats: true) { [weak self] _ in
            self?.verifyHidRemapping(context: "Periodic")
        }
        RunLoop.main.add(timer, forMode: .common)
        remapCheckTimer = timer
    }

    // MARK: - Core State Determination & UI Setup

    private func determineStateAndSetupUI(context: String) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        Logger.state.debug("Determining state (Context: \(context, privacy: .public))...")

        fetchAllSelectableSources()
        updateActiveTargetRefsAndAvailabilityCount()

        let determinedState: AppOperationalState = (state.availableSelectionCount == 2) ? .active : .configuring
        let previousState = state.currentOperationalState
        state.currentOperationalState = determinedState
        Logger.state.info("State Check: Prev=\(previousState.description, privacy: .public), New=\(determinedState.description, privacy: .public)")

        if determinedState == .active {
            // Grab the key first, then remap: there is never a moment where Caps Lock sends an unhandled LANG1.
            registerHotKeys()
            if state.hotKeyError == nil {
                manageHidRemapping(enable: true, context: "Active (\(context))")
            } else {
                // Without the hot key the remap would turn Caps Lock into a dead key. Keep native behaviour.
                manageHidRemapping(enable: false, context: "Hot key unavailable (\(context))")
            }
        } else {
            manageHidRemapping(enable: false, context: "Configuring (\(context))")
            unregisterHotKeys()
        }

        setupStatusBar()
        updateMenuState()

        if determinedState == .configuring && context == "Launch" {
            DispatchQueue.main.async { [weak self] in
                self?.showWelcomeMessageIfNeeded()
            }
        }
    }

    // MARK: - Hot Keys

    private func installHotKeyHandler() {
        guard state.hotKeyHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, eventTypes.count, &eventTypes, selfPtr, &state.hotKeyHandler)
        if status != noErr {
            Logger.hotKey.critical("InstallEventHandler failed: \(status)")
        }
    }

    private func registerHotKeys() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        state.hotKeyError = nil

        if state.switchHotKey == nil {
            let status = RegisterEventHotKey(
                triggerKeyCode, 0,
                EventHotKeyID(signature: AppDelegate.hotKeySignature, id: HotKeyID.switchLayout.rawValue),
                GetApplicationEventTarget(), 0, &state.switchHotKey
            )
            if status != noErr {
                Logger.hotKey.error("RegisterEventHotKey (Caps Lock) failed: \(status)")
                state.switchHotKey = nil
                state.hotKeyError = status
            }
        }

        let capsLockHotKeys: [(id: HotKeyID, modifiers: Int, enabled: Bool)] = [
            (.capsLockWithShift, shiftKey, capsLockViaShift),
            (.capsLockWithCommand, cmdKey, capsLockViaCommand)
        ]
        for hotKey in capsLockHotKeys {
            let id = hotKey.id.rawValue
            if hotKey.enabled, state.capsLockHotKeys[id] == nil {
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    triggerKeyCode, UInt32(hotKey.modifiers),
                    EventHotKeyID(signature: AppDelegate.hotKeySignature, id: id),
                    GetApplicationEventTarget(), 0, &ref
                )
                if status == noErr, let ref = ref {
                    state.capsLockHotKeys[id] = ref
                } else {
                    // Not fatal: plain Caps Lock switching still works.
                    Logger.hotKey.error("RegisterEventHotKey (modifier \(hotKey.modifiers) + Caps Lock) failed: \(status)")
                }
            } else if !hotKey.enabled, let ref = state.capsLockHotKeys.removeValue(forKey: id) {
                UnregisterEventHotKey(ref)
            }
        }
    }

    private func unregisterHotKeys() {
        if let ref = state.switchHotKey {
            UnregisterEventHotKey(ref)
            state.switchHotKey = nil
        }
        for ref in state.capsLockHotKeys.values {
            UnregisterEventHotKey(ref)
        }
        state.capsLockHotKeys.removeAll()
        capsLockHotKeysDownAt.removeAll()
        holdWorkItem?.cancel()
        holdWorkItem = nil
        triggerDownAt = nil
    }

    /// Called on the main thread by the Carbon event handler.
    fileprivate func handleHotKey(id: UInt32, pressed: Bool) {
        guard state.currentOperationalState == .active else { return }
        switch HotKeyID(rawValue: id) {
        case .switchLayout:
            pressed ? triggerPressed() : triggerReleased()
        case .capsLockWithShift, .capsLockWithCommand:
            if !pressed {
                capsLockHotKeysDownAt[id] = nil
            } else if capsLockHotKeysDownAt[id].map({ Date().timeIntervalSince($0) >= 2 }) ?? true {
                // Same 2 s expiry as the plain trigger, in case a release event was lost.
                capsLockHotKeysDownAt[id] = Date()
                setCapsLock(!isCapsLockOn())
            }
        case nil:
            break
        }
    }

    private func triggerPressed() {
        // Ignore duplicate presses while the key is held; a lost release event expires after 2 s.
        if let downAt = triggerDownAt, Date().timeIntervalSince(downAt) < 2 { return }
        triggerDownAt = Date()

        // Like a real Caps Lock: when uppercase is locked, the key just releases it.
        if isCapsLockOn() {
            setCapsLock(false)
            return
        }

        let previousSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        guard switchLayout() else { return }

        guard capsLockViaHold else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.triggerDownAt != nil else { return }
            // Long press: undo the instant switch and lock uppercase instead.
            if let previousSource = previousSource {
                TISSelectInputSource(previousSource)
            }
            self.setCapsLock(true)
            Logger.hotKey.debug("Hold detected: layout restored, Caps Lock ON.")
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: work)
    }

    private func triggerReleased() {
        triggerDownAt = nil
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }

    /// Toggles between the two selected layouts. Returns true if a switch was attempted.
    private func switchLayout() -> Bool {
        guard let source1 = state.targetSource1Ref, let source2 = state.targetSource2Ref else {
            Logger.hotKey.error("Switch FAIL: Missing target refs in Active state.")
            return false
        }
        guard let currentSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let currentSourceID = getInputSourceID(currentSource) else {
            Logger.hotKey.error("Switch FAIL: Could not read the current input source.")
            return false
        }

        // Anything other than layout 1 (layout 2 or a third one picked from the menu bar) goes to layout 1.
        let targetSource = (currentSourceID == state.selectedSourceID1) ? source2 : source1
        let status = TISSelectInputSource(targetSource)
        if status != noErr {
            Logger.hotKey.error("Switch FAILED: TISSelectInputSource returned error \(status).")
        } else {
            Logger.hotKey.debug("Switched from '\(currentSourceID, privacy: .public)'.")
        }
        return true
    }

    // MARK: - Caps Lock State (IOHIDSystem)

    private func isCapsLockOn() -> Bool {
        capsLockController.isOn ?? false
    }

    private func setCapsLock(_ on: Bool) {
        let result = capsLockController.set(on)
        if result != KERN_SUCCESS {
            Logger.hid.error("IOHIDSetModifierLockState(\(on)) failed: \(result)")
        }
    }

    // MARK: - HID Remapping Management (Main Thread Only)

    private func hidutilPayload(enable: Bool) -> String {
        // Reverting maps Caps Lock back to itself explicitly instead of clearing every user mapping.
        let destination = enable ? hidLangKeyUsage : hidCapsLockUsage
        return "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(hidCapsLockUsage),\"HIDKeyboardModifierMappingDst\":\(destination)}]}"
    }

    private func manageHidRemapping(enable: Bool, context: String, force: Bool = false) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard force || state.isHidRemappingApplied != enable else { return }

        // Track the intended state right away so repeated calls don't queue duplicate hidutil runs.
        state.isHidRemappingApplied = enable
        let payload = hidutilPayload(enable: enable)
        Logger.hid.info("hidutil (\(context, privacy: .public)): \(enable ? "ENABLE CapsLock->LANG1" : "REVERT CapsLock->CapsLock")")

        Task.detached(priority: .utility) {
            let (status, output) = AppDelegate.runHidutil(arguments: ["property", "--set", payload])
            if status == 0 {
                Logger.hid.info("hidutil OK (\(context, privacy: .public)).")
            } else {
                Logger.hid.error("hidutil FAILED (status \(status)) (\(context, privacy: .public)): \(output, privacy: .public)")
                await MainActor.run { [weak self] in
                    // Let the next verification retry.
                    if self?.state.isHidRemappingApplied == enable { self?.state.isHidRemappingApplied = !enable }
                }
            }
        }
    }

    private func runHidutilSync(enable: Bool, context: String) {
        let (status, output) = AppDelegate.runHidutil(arguments: ["property", "--set", hidutilPayload(enable: enable)])
        if status == 0 {
            state.isHidRemappingApplied = enable
            Logger.hid.info("hidutil sync OK (\(context, privacy: .public)).")
        } else {
            Logger.hid.error("hidutil sync FAILED (status \(status)) (\(context, privacy: .public)): \(output, privacy: .public)")
        }
    }

    /// Re-applies the remap if something (sleep, keyboard reconnect, another tool) dropped it.
    private func verifyHidRemapping(context: String) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard state.currentOperationalState == .active, state.hotKeyError == nil else { return }

        let srcValue = String(hidCapsLockUsage)
        let dstValue = String(hidLangKeyUsage)
        Task.detached(priority: .utility) {
            let (status, output) = AppDelegate.runHidutil(arguments: ["property", "--get", "UserKeyMapping"])
            let present = status == 0 && output.contains(srcValue) && output.contains(dstValue)
            guard !present else { return }
            await MainActor.run { [weak self] in
                guard let self = self, self.state.currentOperationalState == .active else { return }
                Logger.hid.warning("Remap missing (\(context, privacy: .public)), re-applying.")
                self.manageHidRemapping(enable: true, context: "Verify (\(context))", force: true)
            }
        }
    }

    private static func runHidutil(arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    // MARK: - Secure Input Diagnostics

    /// Name of the process holding Secure Event Input, if any. Shown in the menu for diagnostics only:
    /// the hot key keeps working regardless.
    private func secureInputHolderName() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pidNumber = session?["kCGSSessionSecureInputPID"] as? NSNumber else { return "unknown app" }
        let pid = pid_t(pidNumber.int32Value)
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            return (String(cString: buffer) as NSString).lastPathComponent
        }
        return "pid \(pid)"
    }

    // MARK: - Alert Logic

    private func showWelcomeAlert() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard NSApplication.shared.modalWindow == nil else {
            Logger.ui.warning("Welcome alert skipped: Another modal window is already visible.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Welcome to \(Bundle.main.appName)!"
        alert.informativeText = """
            Ready to configure!

            1. Click the \(Bundle.main.appName) menu bar icon.

            2. Select exactly two keyboard layouts you want to switch between.

            3. Press Caps Lock to instantly toggle between them.

            Need UPPERCASE? Hold Caps Lock, or press Shift + Caps Lock or ⌘ + Caps Lock. Press Caps Lock again to release it.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showWelcomeMessageIfNeeded() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: PrefKeys.hasShownWelcome) {
            showWelcomeAlert()
            defaults.set(true, forKey: PrefKeys.hasShownWelcome)
        }
    }

    // MARK: - Menu Actions (Main Thread)

    @objc func showWelcomeGuideAction() { showWelcomeAlert() }

    @objc func toggleCapsLockViaShift(_ sender: NSMenuItem) {
        capsLockViaShift.toggle()
        determineStateAndSetupUI(context: "CapsLockViaShiftToggled")
    }

    @objc func toggleCapsLockViaCommand(_ sender: NSMenuItem) {
        capsLockViaCommand.toggle()
        determineStateAndSetupUI(context: "CapsLockViaCommandToggled")
    }

    @objc func toggleCapsLockViaHold(_ sender: NSMenuItem) {
        capsLockViaHold.toggle()
        determineStateAndSetupUI(context: "CapsLockViaHoldToggled")
    }

    // MARK: - Status Bar & Menu UI Setup (Main Thread Only)

    private func setupStatusBar() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            guard let button = statusItem?.button else {
                Logger.app.critical("Status bar item button creation failed.")
                NSApplication.shared.terminate(self)
                return
            }
            button.imagePosition = .imageOnly
        }

        if appMenu == nil {
            appMenu = NSMenu()
            appMenu?.delegate = self
            appMenu?.autoenablesItems = false
            statusItem?.menu = appMenu
        }

        // Always clear and rebuild the menu content based on current state
        appMenu?.removeAllItems()
        statusMenuItem = nil

        updateStatusIcon(for: state.currentOperationalState)

        // Structure: Status [Secure Input] -> Sep -> Layouts... -> Sep -> Options... -> Sep -> Quit
        let statusLine = NSMenuItem(title: "Loading Status...", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        appMenu?.addItem(statusLine)
        statusMenuItem = statusLine

        if let holder = secureInputHolderName() {
            let secureLine = NSMenuItem(title: "Secure Input on (\(holder)) — Caps Lock still works", action: nil, keyEquivalent: "")
            secureLine.isEnabled = false
            secureLine.toolTip = "Another app enabled Secure Event Input. Tools based on event taps stop seeing keys; this app uses a system hot key and is not affected."
            appMenu?.addItem(secureLine)
        }

        appMenu?.addItem(NSMenuItem.separator())
        // Layout items are inserted here by updateLayoutMenuItems
        appMenu?.addItem(NSMenuItem.separator())

        let shiftItem = NSMenuItem(title: "Shift + Caps Lock → UPPERCASE", action: #selector(toggleCapsLockViaShift(_:)), keyEquivalent: "")
        shiftItem.target = self
        shiftItem.state = capsLockViaShift ? .on : .off
        appMenu?.addItem(shiftItem)

        let commandItem = NSMenuItem(title: "⌘ + Caps Lock → UPPERCASE", action: #selector(toggleCapsLockViaCommand(_:)), keyEquivalent: "")
        commandItem.target = self
        commandItem.state = capsLockViaCommand ? .on : .off
        appMenu?.addItem(commandItem)

        let holdItem = NSMenuItem(title: "Hold Caps Lock → UPPERCASE", action: #selector(toggleCapsLockViaHold(_:)), keyEquivalent: "")
        holdItem.target = self
        holdItem.state = capsLockViaHold ? .on : .off
        appMenu?.addItem(holdItem)

        appMenu?.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch on Startup", action: #selector(toggleLaunchOnStartup(_:)), keyEquivalent: "l")
        launchItem.target = self
        launchItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        appMenu?.addItem(launchItem)

        let welcomeItem = NSMenuItem(title: "Show Welcome Guide", action: #selector(showWelcomeGuideAction), keyEquivalent: "w")
        welcomeItem.target = self
        appMenu?.addItem(welcomeItem)

        appMenu?.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit \(Bundle.main.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu?.addItem(quitItem)
    }

    private func updateStatusIcon(for operationalState: AppOperationalState) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard let button = statusItem?.button else { return }

        let iconName: String
        let fallbackTitle: String
        let tooltip: String

        if state.hotKeyError != nil {
            iconName = "exclamationmark.triangle.fill"
            fallbackTitle = "⚠️"
            tooltip = "\(Bundle.main.appName): Caps Lock hot key unavailable"
        } else {
            switch operationalState {
            case .configuring:
                iconName = "keyboard.badge.ellipsis"
                fallbackTitle = "⚙️"
                tooltip = "\(Bundle.main.appName): Configuring - Select Layouts"
            case .active:
                iconName = "keyboard.fill"
                fallbackTitle = "⌨️"
                tooltip = "\(Bundle.main.appName): Active (Caps Lock Remapped)"
            }
        }

        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = fallbackTitle
        }
        button.toolTip = tooltip
    }

    private func updateMenuState() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        guard let menu = appMenu else { return }

        if let statusItem = self.statusMenuItem {
            if let error = state.hotKeyError {
                statusItem.title = "Caps Lock hot key unavailable (error \(error))"
            } else {
                switch state.currentOperationalState {
                case .active:
                    statusItem.title = "Switcher: Active"
                case .configuring:
                    statusItem.title = (state.availableSelectionCount == 1) ? "Select 1 more layout..." : "Select 2 layouts..."
                }
            }
        }

        updateLayoutMenuItems(in: menu)
    }

    private func updateLayoutMenuItems(in menu: NSMenu) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        // Assumes structure: Status -> Sep -> Layouts... -> Sep -> Options...
        guard let firstSepIndex = menu.items.firstIndex(where: { $0.isSeparatorItem }),
              let secondSep = menu.items[(firstSepIndex + 1)...].first(where: { $0.isSeparatorItem }),
              let secondSepIndex = menu.items.firstIndex(of: secondSep) else {
            Logger.ui.error("Layout separators not found correctly for updateLayoutMenuItems. Menu structure might be wrong.")
            return
        }

        for i in ((firstSepIndex + 1)..<secondSepIndex).reversed() {
            menu.removeItem(at: i)
        }
        state.menuItemToSourceMap.removeAll()

        let insertIndex = firstSepIndex + 1
        for (offset, source) in state.allSelectableSources.enumerated() {
            guard let name = getInputSourceLocalizedName(source), let id = getInputSourceID(source) else { continue }

            let menuItem = NSMenuItem(title: name, action: #selector(layoutMenuItemSelected(_:)), keyEquivalent: "")
            menuItem.target = self

            let isSelected = (id == state.selectedSourceID1 || id == state.selectedSourceID2)
            menuItem.state = isSelected ? .on : .off

            // Can select if < 2 already selected, or if deselecting this one
            let canSelectMore = (state.targetSource1Ref == nil || state.targetSource2Ref == nil)
            menuItem.isEnabled = isSelected || canSelectMore
            menuItem.toolTip = "Keyboard Layout: \(name) (\(id))"

            menu.insertItem(menuItem, at: insertIndex + offset)
            state.menuItemToSourceMap[menuItem] = source
        }

        if state.currentOperationalState == .configuring && state.allSelectableSources.isEmpty {
            let noSourcesItem = NSMenuItem(title: "(No keyboard layouts found)", action: nil, keyEquivalent: "")
            noSourcesItem.isEnabled = false
            menu.insertItem(noSourcesItem, at: insertIndex)
        }
    }

    // MARK: - Launch on Startup Logic (Using SMAppService)

    private func performLaunchOnStartupUpdate(enable: Bool) async -> (status: SMAppService.Status, error: Error?) {
        do {
            if enable {
                try SMAppService.mainApp.register()
                Logger.app.info("Launch on Startup: Registered successfully.")
            } else {
                try await SMAppService.mainApp.unregister()
                Logger.app.info("Launch on Startup: Unregistered successfully.")
            }
            return (SMAppService.mainApp.status, nil)
        } catch {
            Logger.app.error("Launch on Startup: \(enable ? "Registration" : "Unregistration") failed: \(error.localizedDescription)")
            return (SMAppService.mainApp.status, error)
        }
    }

    @objc func toggleLaunchOnStartup(_ sender: NSMenuItem) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let shouldEnable = (sender.state == .off)
        let targetSelector = #selector(toggleLaunchOnStartup(_:))

        Task(priority: .userInitiated) {
            let result = await performLaunchOnStartupUpdate(enable: shouldEnable)
            await MainActor.run { [weak self] in
                self?.updateLaunchOnStartupMenuItem(selector: targetSelector, status: result.status, error: result.error)
            }
        }
    }

    private func updateLaunchOnStartupMenuItem(selector: Selector, status: SMAppService.Status, error: Error?) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        if let menuItem = self.appMenu?.items.first(where: { $0.action == selector }) {
            menuItem.state = (status == .enabled) ? .on : .off
        }

        if let error = error {
            guard NSApplication.shared.modalWindow == nil else { return }
            let alert = NSAlert()
            alert.messageText = "Launch on Startup Error"
            alert.informativeText = "Could not update the 'Launch on Startup' setting.\n\nError: \(error.localizedDescription)\n\nYou may need to manage this manually in System Settings > General > Login Items."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Always run the full state check when menu opens to ensure UI is correct
        determineStateAndSetupUI(context: "MenuOpen")
        verifyHidRemapping(context: "MenuOpen")
    }

    // MARK: - Input Source (TIS) Handling (Main Thread Only)

    private func fetchAllSelectableSources() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        let filter = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as String,
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue!
        ] as CFDictionary

        guard let sourcesList = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            Logger.settings.error("TISCreateInputSourceList failed. Cannot fetch input sources.")
            state.allSelectableSources = []
            return
        }

        state.allSelectableSources = sourcesList.filter { source in
            guard let id = getInputSourceID(source), id.lowercased() != "null" else { return false }
            return getInputSourceLocalizedName(source) != nil
        }
    }

    private func updateActiveTargetRefsAndAvailabilityCount() {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        state.targetSource1Ref = nil
        state.targetSource2Ref = nil
        state.availableSelectionCount = 0

        let id1 = state.selectedSourceID1
        let id2 = state.selectedSourceID2
        guard id1 != nil || id2 != nil else { return }

        for source in state.allSelectableSources {
            guard let sourceID = getInputSourceID(source) else { continue }
            if sourceID == id1 {
                state.targetSource1Ref = source
            } else if sourceID == id2 {
                state.targetSource2Ref = source
            }
        }

        // availableSelectionCount is how many *selected* layouts are *currently usable*
        state.availableSelectionCount = (state.targetSource1Ref != nil ? 1 : 0) + (state.targetSource2Ref != nil ? 1 : 0)

        if id1 != nil && state.targetSource1Ref == nil {
            Logger.state.warning("Selected layout ID '\(id1!, privacy: .public)' is not currently enabled or available.")
        }
        if id2 != nil && state.targetSource2Ref == nil {
            Logger.state.warning("Selected layout ID '\(id2!, privacy: .public)' is not currently enabled or available.")
        }
    }

    @objc func layoutMenuItemSelected(_ sender: NSMenuItem) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

        guard let selectedSource = state.menuItemToSourceMap[sender],
              let selectedID = getInputSourceID(selectedSource) else {
            NSSound.beep()
            return
        }

        let userDefaults = UserDefaults.standard
        let wasSelected = (sender.state == .on)

        if wasSelected {
            if state.selectedSourceID1 == selectedID {
                state.selectedSourceID1 = nil
                userDefaults.removeObject(forKey: PrefKeys.selectedSourceID1)
            } else if state.selectedSourceID2 == selectedID {
                state.selectedSourceID2 = nil
                userDefaults.removeObject(forKey: PrefKeys.selectedSourceID2)
            }
        } else {
            // Uses the *live* TIS refs, which is more accurate than just checking IDs
            let slot1Filled = state.targetSource1Ref != nil
            let slot2Filled = state.targetSource2Ref != nil

            if !slot1Filled {
                state.selectedSourceID1 = selectedID
                userDefaults.set(selectedID, forKey: PrefKeys.selectedSourceID1)
            } else if !slot2Filled {
                state.selectedSourceID2 = selectedID
                userDefaults.set(selectedID, forKey: PrefKeys.selectedSourceID2)
            } else {
                NSSound.beep()
                return
            }
        }

        determineStateAndSetupUI(context: wasSelected ? "LayoutDeselected" : "LayoutSelected")
    }

    // MARK: - Helper Functions

    /// Safely gets the Input Source ID (e.g., "com.apple.keylayout.US")
    private func getInputSourceID(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Safely gets the Input Source Localized Name (e.g., "U.S.")
    private func getInputSourceLocalizedName(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

} // End of AppDelegate class

// MARK: - Bundle Extension

extension Bundle {
    var appName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
        object(forInfoDictionaryKey: "CFBundleName") as? String ??
        "CapsLockSwitcher"
    }
}
