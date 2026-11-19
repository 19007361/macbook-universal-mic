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

// MARK: - Menu bar app

final class App: NSObject, NSApplicationDelegate {
    let gate = Gate()
    var item: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?
    let hud = HUD()
    var holdTimer: Timer?
    var holdFired = false

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
        gate.start()
        registerHotKey()
        tryInstallKeyTap(prompt: true)
        refresh()
    }

    /// ⌘ + the keyboard's mic key. The mic key sends key code 176 on its own, but
    /// ⌘+mic arrives as ⌘+F5 (key code 96). Swallow that combo and toggle mute.
    /// Needs Accessibility permission; retries until it is granted.
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
            if code == 96 && ev.flags.contains(.maskCommand) {
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
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.tryInstallKeyTap(prompt: false)
            }
        }
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
        m.addItem(NSMenuItem(title: "Hold the icon, ⌘-click, or ⌘+mic key to toggle", action: nil, keyEquivalent: ""))
        if keyTapPort == nil {
            m.addItem(NSMenuItem(title: "⚠︎ ⌘+mic key off: allow MicGate in Privacy › Accessibility", action: nil, keyEquivalent: ""))
        }
        let bad = gate.uncontrollable
        if !bad.isEmpty {
            m.addItem(NSMenuItem(title: "⚠︎ Can't mute: " + bad.joined(separator: ", "), action: nil, keyEquivalent: ""))
        }
        m.addItem(.separator())
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
        item.button?.toolTip = "All mics: " + (gate.muted ? "MUTED" : "live") + " — hold or ⌘-click to toggle, ⌃⌥⌘M"
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { appDelegate.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4d475431), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
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
