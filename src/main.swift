import Cocoa
import CoreAudio
import Carbon.HIToolbox

var keyTapPort: CFMachPort?

// MARK: - CoreAudio helpers

func inAddr(_ sel: AudioObjectPropertySelector, _ el: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeInput, mElement: el)
}

func canSet(_ d: AudioDeviceID, _ p: inout AudioObjectPropertyAddress) -> Bool {
    guard AudioObjectHasProperty(d, &p) else { return false }
    var s: DarwinBoolean = false
    AudioObjectIsPropertySettable(d, &p, &s)
    return s.boolValue
}

func stringProp(_ d: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>? = nil
    var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &ref)
    return (ref?.takeRetainedValue() as String?) ?? "\(d)"
}

func defaultInput() -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var d = AudioDeviceID(0)
    var s = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d)
    return d
}

func transportType(_ d: AudioDeviceID) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var t: UInt32 = 0
    var s = UInt32(4)
    AudioObjectGetPropertyData(d, &a, 0, nil, &s, &t)
    return t
}

/// Every real input device (built-in, USB, Bluetooth...). Virtual and aggregate
/// devices (BlackHole, Loopback, etc.) are left alone so audio routing keeps working.
func physicalInputs() -> [AudioDeviceID] {
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids)
    return ids.filter { d in
        var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                            mScope: kAudioDevicePropertyScopeInput, mElement: 0)
        var ss: UInt32 = 0
        AudioObjectGetPropertyDataSize(d, &sa, 0, nil, &ss)
        let t = transportType(d)
        return ss > 0 && t != kAudioDeviceTransportTypeVirtual && t != kAudioDeviceTransportTypeAggregate
    }
}

// MARK: - Gate: mutes every physical mic and keeps them muted

final class Gate {
    var muted: Bool { didSet { UserDefaults.standard.set(muted, forKey: "muted") } }
    var dev: AudioDeviceID = 0              // current default input (shown in the UI)
    var devices: [AudioDeviceID] = []       // every physical mic we gate
    var onChange: (() -> Void)?
    private var devBlock: AudioObjectPropertyListenerBlock?
    private var listening: [AudioDeviceID] = []
    private let elements: [UInt32] = [0, 1, 2, 3, 4]

    init() { muted = UserDefaults.standard.bool(forKey: "muted") }

    var deviceName: String { dev == 0 ? "none" : stringProp(dev, kAudioObjectPropertyName) }
    var gatedNames: [String] { devices.map { stringProp($0, kAudioObjectPropertyName) } }
    var uncontrollable: [String] {
        devices.filter { !hasControls($0) }.map { stringProp($0, kAudioObjectPropertyName) }
    }

    func start() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(sys, &a, .main) { [weak self] _, _ in self?.rescan() }
        }
        devBlock = { [weak self] _, _ in self?.enforce() }
        rescan()
    }

    /// Devices come and go (plugging a headset in): gate whatever is present now.
    private func rescan() {
        dev = defaultInput()
        let now = physicalInputs()
        for d in listening where !now.contains(d) { forEachProperty(d) { AudioObjectRemovePropertyListenerBlock(d, &$0, .main, devBlock!) } }
        for d in now where !listening.contains(d) { forEachProperty(d) { AudioObjectAddPropertyListenerBlock(d, &$0, .main, devBlock!) } }
        listening = now
        devices = now
        apply()
    }

    private func forEachProperty(_ d: AudioDeviceID, _ body: (inout AudioObjectPropertyAddress) -> Void) {
        for sel in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            for el in elements {
                var p = inAddr(sel, el)
                body(&p)
            }
        }
    }

    func apply() {
        for d in devices { setState(d, muted: muted) }
        onChange?()
    }

    /// Called whenever mute/volume on any mic changes (e.g. Zoom or Granola unmuting).
    func enforce() {
        if muted {
            for d in devices where !isSilenced(d) { setState(d, muted: true) }
        }
        onChange?()
    }

    func isSilenced(_ d: AudioDeviceID) -> Bool {
        var sawControl = false
        for el in elements {
            var p = inAddr(kAudioDevicePropertyMute, el)
            if canSet(d, &p) {
                sawControl = true
                var v: UInt32 = 0; var s = UInt32(4)
                AudioObjectGetPropertyData(d, &p, 0, nil, &s, &v)
                if v == 0 { return false }
            }
            var q = inAddr(kAudioDevicePropertyVolumeScalar, el)
            if canSet(d, &q) {
                sawControl = true
                var v: Float32 = 0; var s = UInt32(4)
                AudioObjectGetPropertyData(d, &q, 0, nil, &s, &v)
                if v > 0 { return false }
            }
        }
        return sawControl
    }

    func hasControls(_ d: AudioDeviceID) -> Bool {
        for el in elements {
            var p = inAddr(kAudioDevicePropertyMute, el)
            var q = inAddr(kAudioDevicePropertyVolumeScalar, el)
            if canSet(d, &p) || canSet(d, &q) { return true }
        }
        return false
    }

    func setState(_ d: AudioDeviceID, muted m: Bool) {
        guard d != 0 else { return }
        let uid = stringProp(d, kAudioDevicePropertyDeviceUID)
        for el in elements {
            var p = inAddr(kAudioDevicePropertyMute, el)
            if canSet(d, &p) {
                var v: UInt32 = m ? 1 : 0
                AudioObjectSetPropertyData(d, &p, 0, nil, 4, &v)
            }
            var q = inAddr(kAudioDevicePropertyVolumeScalar, el)
            if canSet(d, &q) {
                var cur: Float32 = 0; var s = UInt32(4)
                AudioObjectGetPropertyData(d, &q, 0, nil, &s, &cur)
                let key = "vol-\(uid)-\(el)"
                if m {
                    if cur > 0 { UserDefaults.standard.set(cur, forKey: key) }
                    var z: Float32 = 0
                    AudioObjectSetPropertyData(d, &q, 0, nil, 4, &z)
                } else if cur == 0 {
                    var r = (UserDefaults.standard.object(forKey: key) as? Float32) ?? 0.75
                    AudioObjectSetPropertyData(d, &q, 0, nil, 4, &r)
                }
            }
        }
    }
}

// MARK: - HUD popup under the menu bar

final class HUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(muted: Bool, below button: NSStatusBarButton?) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let size = NSSize(width: 240, height: 210)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 22
        fx.layer?.masksToBounds = true

        let color: NSColor = muted ? .systemRed : .systemGreen
        let cfg = NSImage.SymbolConfiguration(pointSize: 88, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        let iv = NSImageView(frame: NSRect(x: 0, y: 70, width: size.width, height: 120))
        iv.image = img
        iv.imageAlignment = .alignCenter
        iv.imageScaling = .scaleNone
        fx.addSubview(iv)

        let label = NSTextField(labelWithString: muted ? "You are muted" : "Mic is live")
        label.font = .systemFont(ofSize: 23, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 26, width: size.width, height: 32)
        fx.addSubview(label)
        p.contentView = fx

        // Position centered under the status item, clamped to the screen.
        let bw = button?.window
        let screen = bw?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let anchorX = bw?.frame.midX ?? vis.midX
        let top = bw?.frame.minY ?? vis.maxY
        let x = min(max(anchorX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        p.setFrameOrigin(NSPoint(x: x, y: top - size.height - 8))

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        let work = DispatchWorkItem { [weak self] in
            guard let p = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (muted ? 1.8 : 1.2), execute: work)
    }
}

// MARK: - Shortcuts

struct Shortcut: Equatable {
    var keyCode: Int64
    var mods: UInt64      // subset of ⌃⌥⇧⌘ as CGEventFlags bits
    var label: String     // key name shown in the UI, e.g. "M" or "F5"

    static let modMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

    var display: String {
        var s = ""
        if mods & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if mods & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if mods & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if mods & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        return s + label
    }

    func matches(_ code: Int64, _ flags: CGEventFlags) -> Bool {
        code == keyCode && (flags.rawValue & Shortcut.modMask) == mods
    }

    func sameKeys(_ o: Shortcut) -> Bool { keyCode == o.keyCode && mods == o.mods }

    var carbonMods: UInt32 {
        var m = 0
        if mods & CGEventFlags.maskCommand.rawValue != 0 { m |= cmdKey }
        if mods & CGEventFlags.maskAlternate.rawValue != 0 { m |= optionKey }
        if mods & CGEventFlags.maskControl.rawValue != 0 { m |= controlKey }
        if mods & CGEventFlags.maskShift.rawValue != 0 { m |= shiftKey }
        return UInt32(m)
    }

    static let fKeyNames: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static let namedKeys: [Int64: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→",
        125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 176: "Mic key",
    ]

    static func label(for code: Int64, chars: String?) -> String {
        if let n = fKeyNames[code] ?? namedKeys[code] { return n }
        if let c = chars, let sc = c.unicodeScalars.first, sc.value >= 0x21, sc.value < 0xF700 {
            return c.uppercased()
        }
        return "Key \(code)"
    }

    /// Needs a modifier unless it's an F-key or special key, so normal typing isn't hijacked.
    var isAllowed: Bool { mods != 0 || Shortcut.fKeyNames[keyCode] != nil || keyCode >= 160 }

    static let factory: [Shortcut?] = [
        Shortcut(keyCode: Int64(kVK_ANSI_M),
                 mods: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue,
                 label: "M"),
        Shortcut(keyCode: 96, mods: CGEventFlags.maskCommand.rawValue, label: "F5"),   // ⌘ + mic key
    ]
}

extension Shortcut {
    init?(dict: [String: Any]) {
        guard let k = (dict["k"] as? NSNumber)?.int64Value,
              let m = (dict["m"] as? NSNumber)?.int64Value,
              let l = dict["l"] as? String else { return nil }
        self.init(keyCode: k, mods: UInt64(m), label: l)
    }
    var dict: [String: Any] { ["k": NSNumber(value: keyCode), "m": NSNumber(value: Int64(mods)), "l": label] }
}

enum ShortcutStore {
    static let slots = 2
    static func load() -> [Shortcut?] {
        guard let arr = UserDefaults.standard.array(forKey: "shortcuts") as? [[String: Any]], arr.count == slots else {
            return Shortcut.factory
        }
        return arr.map { Shortcut(dict: $0) }
    }
    static func save(_ s: [Shortcut?]) {
        UserDefaults.standard.set(s.map { $0?.dict ?? [:] }, forKey: "shortcuts")
    }
}

/// Read by the key tap callback (a C function pointer, so these must be globals).
var activeShortcuts: [Shortcut?] = []
var recordHandler: ((Shortcut) -> Void)?

// MARK: - Settings window

final class SettingsWindow: NSObject, NSWindowDelegate {
    unowned let app: App
    let window: NSWindow
    private var fields: [NSTextField] = []
    private var recordButtons: [NSButton] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let axButton = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
    private var recordingSlot: Int?
    private var localMonitor: Any?

    init(app: App) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "MicGate Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let v = window.contentView!

        let title = NSTextField(labelWithString: "Toggle-mute shortcuts")
        title.font = .boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 20, y: 228, width: 440, height: 22)
        v.addSubview(title)

        for i in 0..<ShortcutStore.slots {
            let y = CGFloat(186 - i * 40)
            let l = NSTextField(labelWithString: "Shortcut \(i + 1)")
            l.frame = NSRect(x: 20, y: y + 4, width: 80, height: 20)
            v.addSubview(l)

            let f = NSTextField(labelWithString: "")
            f.isBezeled = true
            f.bezelStyle = .roundedBezel
            f.drawsBackground = true
            f.alignment = .center
            f.font = .systemFont(ofSize: 15, weight: .medium)
            f.frame = NSRect(x: 100, y: y, width: 150, height: 28)
            v.addSubview(f)
            fields.append(f)

            let r = NSButton(title: "Record", target: self, action: #selector(record(_:)))
            r.tag = i
            r.bezelStyle = .rounded
            r.frame = NSRect(x: 258, y: y, width: 130, height: 28)
            v.addSubview(r)
            recordButtons.append(r)

            let c = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
            c.tag = i
            c.bezelStyle = .rounded
            c.frame = NSRect(x: 390, y: y, width: 70, height: 28)
            v.addSubview(c)
        }

        let tip = NSTextField(wrappingLabelWithString:
            "Click Record, then press the keys. Esc cancels. ⌘ + the mic key on Mac keyboards records as ⌘F5. " +
            "Holding or ⌘-clicking the menu-bar icon always works too.")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.frame = NSRect(x: 20, y: 86, width: 440, height: 30)
        v.addSubview(tip)

        status.font = .systemFont(ofSize: 11)
        status.frame = NSRect(x: 20, y: 48, width: 440, height: 30)
        v.addSubview(status)

        axButton.target = self
        axButton.action = #selector(openAccessibility)
        axButton.bezelStyle = .rounded
        axButton.frame = NSRect(x: 16, y: 12, width: 220, height: 28)
        v.addSubview(axButton)

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 314, y: 12, width: 150, height: 28)
        v.addSubview(reset)
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        for i in 0..<ShortcutStore.slots {
            let s = i < activeShortcuts.count ? activeShortcuts[i] : nil
            fields[i].stringValue = recordingSlot == i ? "…" : (s?.display ?? "None")
            recordButtons[i].title = recordingSlot == i ? "Press keys…" : "Record"
        }
        if keyTapPort != nil {
            status.stringValue = "✓ Shortcuts are captured before other apps, so they also override system shortcuts like ⌘F5."
            status.textColor = .secondaryLabelColor
            axButton.isHidden = true
        } else {
            status.stringValue = "⚠︎ Accessibility is off for MicGate. Shortcuts that clash with system shortcuts " +
                "(like ⌘F5, the ⌘ + mic key) won't work until you allow it."
            status.textColor = .systemOrange
            axButton.isHidden = false
        }
    }

    @objc func record(_ sender: NSButton) { startRecording(sender.tag) }

    @objc func clear(_ sender: NSButton) {
        stopRecording()
        var s = ShortcutStore.load()
        s[sender.tag] = nil
        ShortcutStore.save(s)
        app.applyShortcuts()
    }

    @objc func resetDefaults() {
        stopRecording()
        ShortcutStore.save(Shortcut.factory)
        app.applyShortcuts()
    }

    @objc func openAccessibility() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    private func startRecording(_ slot: Int) {
        stopRecording()
        recordingSlot = slot
        let finish: (Shortcut) -> Void = { [weak self] sc in self?.finishRecording(sc) }
        if keyTapPort != nil {
            // The tap sees the keys first, so even system combos like ⌘F5 can be recorded.
            recordHandler = finish
        } else {
            app.unregisterCarbon()
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                var mods: UInt64 = 0
                if e.modifierFlags.contains(.command) { mods |= CGEventFlags.maskCommand.rawValue }
                if e.modifierFlags.contains(.option) { mods |= CGEventFlags.maskAlternate.rawValue }
                if e.modifierFlags.contains(.control) { mods |= CGEventFlags.maskControl.rawValue }
                if e.modifierFlags.contains(.shift) { mods |= CGEventFlags.maskShift.rawValue }
                let code = Int64(e.keyCode)
                finish(Shortcut(keyCode: code, mods: mods,
                                label: Shortcut.label(for: code, chars: e.charactersIgnoringModifiers)))
                return nil
            }
        }
        reload()
    }

    private func finishRecording(_ sc: Shortcut) {
        guard let slot = recordingSlot else { return }
        if sc.keyCode == 53 && sc.mods == 0 {          // Esc: cancel
            stopRecording()
            app.applyShortcuts()
            return
        }
        if !sc.isAllowed { NSSound.beep(); return }   // plain letter etc.: keep listening
        stopRecording()
        var s = ShortcutStore.load()
        for i in s.indices where i != slot && s[i].map({ $0.sameKeys(sc) }) == true { s[i] = nil }
        s[slot] = sc
        ShortcutStore.save(s)
        app.applyShortcuts()
    }

    private func stopRecording() {
        recordHandler = nil
        recordingSlot = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    func windowWillClose(_ notification: Notification) {
        if recordingSlot != nil {
            stopRecording()
            app.applyShortcuts()
        }
    }
}

// MARK: - Menu bar app

final class App: NSObject, NSApplicationDelegate {
    let gate = Gate()
    var item: NSStatusItem!
    let hud = HUD()
    var holdTimer: Timer?
    var holdFired = false
    var carbonRefs: [EventHotKeyRef] = []
    lazy var settings = SettingsWindow(app: self)

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(click)
        item.button?.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
        gate.onChange = { [weak self] in self?.refresh() }
        if CommandLine.arguments.contains("--demo-hud") {
            // Visual check only: show the popup, don't touch the mic, then exit.
            let muted = !CommandLine.arguments.contains("live")
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.hud.show(muted: muted, below: self.item.button) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { NSApp.terminate(nil) }
            return
        }
        if CommandLine.arguments.contains("--demo-settings") {
            // Visual check only: show the Settings window, don't touch the mic, then exit.
            activeShortcuts = ShortcutStore.load()
            refresh()
            settings.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.terminate(nil) }
            return
        }
        gate.start()
        installCarbonHandler()
        applyShortcuts()
        tryInstallKeyTap(prompt: true)
        refresh()
    }

    /// Key tap: catches the configured shortcuts before any other app or system
    /// shortcut (e.g. ⌘F5 = ⌘ + mic key, which macOS uses for VoiceOver) and swallows them.
    /// Needs Accessibility permission; retries until it is granted. Without it,
    /// shortcuts fall back to normal global hotkeys.
    func tryInstallKeyTap(prompt: Bool) {
        if keyTapPort != nil { return }
        if prompt {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let cb: CGEventTapCallBack = { _, type, ev, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = keyTapPort { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(ev)
            }
            let code = ev.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown, let h = recordHandler {
                let chars = NSEvent(cgEvent: ev)?.charactersIgnoringModifiers
                let sc = Shortcut(keyCode: code, mods: ev.flags.rawValue & Shortcut.modMask,
                                  label: Shortcut.label(for: code, chars: chars))
                DispatchQueue.main.async { h(sc) }
                return nil
            }
            for case let s? in activeShortcuts where s.matches(code, ev.flags) {
                if type == .keyDown && ev.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { appDelegate.toggle() }
                }
                return nil
            }
            return Unmanaged.passUnretained(ev)
        }
        if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: cb, userInfo: nil) {
            keyTapPort = t
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            applyShortcuts()   // the tap handles shortcuts now; drop the fallback hotkeys
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.tryInstallKeyTap(prompt: false)
            }
        }
    }

    func installCarbonHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { appDelegate.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func unregisterCarbon() {
        for r in carbonRefs { UnregisterEventHotKey(r) }
        carbonRefs = []
    }

    /// Load shortcuts from settings. With the key tap active the tap handles them;
    /// otherwise register them as ordinary global hotkeys.
    func applyShortcuts() {
        activeShortcuts = ShortcutStore.load()
        unregisterCarbon()
        if keyTapPort == nil {
            for (i, s) in activeShortcuts.enumerated() {
                guard let s else { continue }
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x4d475431), id: UInt32(i + 1))
                if RegisterEventHotKey(UInt32(s.keyCode), s.carbonMods, id, GetApplicationEventTarget(), 0, &ref) == noErr,
                   let ref {
                    carbonRefs.append(ref)
                }
            }
        }
        refresh()
        if settings.window.isVisible { settings.reload() }
    }

    var shortcutSummary: String {
        let s = activeShortcuts.compactMap { $0?.display }
        return s.isEmpty ? "no shortcuts set" : s.joined(separator: ", ")
    }

    /// Plain click = menu. Hold (~0.45s) or ⌘-click = toggle mute. Right-click = menu.
    @objc func click() {
        guard let e = NSApp.currentEvent else { return }
        switch e.type {
        case .leftMouseDown:
            holdFired = false
            holdTimer?.invalidate()
            if e.modifierFlags.contains(.command) {
                holdFired = true
                toggle()
            } else {
                let t = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
                    self?.holdFired = true
                    self?.holdTimer = nil
                    self?.toggle()
                }
                RunLoop.main.add(t, forMode: .common)
                holdTimer = t
            }
        case .leftMouseUp:
            holdTimer?.invalidate()
            holdTimer = nil
            if holdFired { holdFired = false } else { showMenu() }
        case .rightMouseUp:
            showMenu()
        default:
            break
        }
    }

    @objc func toggle() {
        gate.muted.toggle()
        gate.apply()
        hud.show(muted: gate.muted, below: item.button)
    }

    @objc func openSettings() { settings.show() }

    @objc func quit() {
        // Leave the mic usable when the app exits.
        gate.muted = false
        for d in gate.devices { gate.setState(d, muted: false) }
        NSApp.terminate(nil)
    }

    func showMenu() {
        let m = NSMenu()
        let t = NSMenuItem(title: gate.muted ? "Unmute mic" : "Mute mic", action: #selector(toggle), keyEquivalent: "")
        t.target = self
        m.addItem(t)
        m.addItem(NSMenuItem(title: "Mics: " + gate.gatedNames.joined(separator: ", "), action: nil, keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Toggle: hold or ⌘-click icon, " + shortcutSummary, action: nil, keyEquivalent: ""))
        if keyTapPort == nil {
            m.addItem(NSMenuItem(title: "⚠︎ Accessibility off: system-clashing shortcuts (⌘F5) won't work",
                                 action: nil, keyEquivalent: ""))
        }
        let bad = gate.uncontrollable
        if !bad.isEmpty {
            m.addItem(NSMenuItem(title: "⚠︎ Can't mute: " + bad.joined(separator: ", "), action: nil, keyEquivalent: ""))
        }
        m.addItem(.separator())
        let s = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        m.addItem(s)
        let q = NSMenuItem(title: "Quit (unmutes)", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        m.addItem(q)
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    func refresh() {
        var img = NSImage(systemSymbolName: gate.muted ? "mic.slash.fill" : "mic.fill",
                          accessibilityDescription: gate.muted ? "Mic muted" : "Mic live")
        if gate.muted {
            // Palette-colored, non-template image so the menu bar keeps it red.
            img = img?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            img?.isTemplate = false
        } else {
            img?.isTemplate = true
        }
        item.button?.image = img
        item.button?.contentTintColor = nil
        item.button?.toolTip = "All mics: " + (gate.muted ? "MUTED" : "live") +
            " — hold or ⌘-click to toggle; " + shortcutSummary
    }
}

let appDelegate = App()

// MARK: - Entry

func selfTest() {
    let g = Gate()
    let original = g.muted
    g.muted = true
    g.start()
    print("gating:", g.gatedNames, "| can't mute:", g.uncontrollable)
    func all() -> Bool { g.devices.filter { g.hasControls($0) }.allSatisfy { g.isSilenced($0) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        print("1. all mics silenced:", all())
        for d in g.devices { g.setState(d, muted: false) }   // simulate an app unmuting every mic
        print("2. right after fake unmute, all silenced:", all())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            print("3. after enforcement, all silenced:", all())
            g.muted = false
            g.apply()
            print("4. after unmute, any mic silenced:", g.devices.contains { g.hasControls($0) && g.isSilenced($0) })
            g.muted = original
            g.apply()
            print("5. restored original state (muted=\(original)), all silenced:", all())
            exit(0)
        }
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--selftest") {
    selfTest()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = appDelegate
    app.run()
}
