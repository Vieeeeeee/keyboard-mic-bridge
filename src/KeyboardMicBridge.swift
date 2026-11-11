import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import IOKit.hid

final class Capture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let consume: (AVAudioPCMBuffer) -> Void
    init(name: String, consume: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.consume = consume
        super.init()
        let available = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        guard let device = available.first(where: { $0.localizedName == name }) else {
            throw NSError(domain: "MicBridge", code: 8, userInfo: [NSLocalizedDescriptionKey: "AVCapture 未找到输入：\(name)"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "KeyboardMicBridge.capture"))
        guard session.canAddInput(input), session.canAddOutput(output) else { throw NSError(domain: "MicBridge", code: 9) }
        session.addInput(input); session.addOutput(output)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        consume(pcm)
    }
}

// This helper forwards audio only; speech recognition remains in the user's input method.
struct Intent {
    var downAt: TimeInterval?
    var latched = false
    var remote = false
    var remoteSince: TimeInterval = 0
    var stoppingTap = false
    var blockedUntil: TimeInterval = 0
    mutating func remoteChanged(_ active: Bool, now: TimeInterval) {
        remote = active
        remoteSince = now
        cancel()
        blockedUntil = now + 0.4
    }
    mutating func cancel() { downAt = nil; latched = false; stoppingTap = false }
    mutating func key(_ down: Bool, now: TimeInterval) {
        // The remote streams at most ~60 s; a missed STOP line must not lock the keyboard out forever.
        if remote && now - remoteSince > 75 { remote = false }
        guard !remote else { return }
        if down {
            if stoppingTap { return }
            if latched { latched = false; downAt = nil; stoppingTap = true }
            else { downAt = now }
        } else if stoppingTap {
            stoppingTap = false
        } else if let start = downAt {
            downAt = nil
            latched = now - start < 0.3
        }
    }
    func wantsAudio(now: TimeInterval) -> Bool {
        !remote && now >= blockedUntil && (latched || downAt.map { now - $0 >= 0.2 } == true)
    }
    // Doubao ends its session on any key press or mouse click (Return commits, others cancel); end ours too.
    // Doubao does not inject key events when it commits text (checked 2026-11-11), so this cannot self-trigger.
    mutating func otherInput() { latched = false }
}

func selfCheck() {
    var s = Intent()
    s.key(true, now: 1); precondition(!s.wantsAudio(now: 1.1))
    precondition(s.wantsAudio(now: 1.25))
    s.key(false, now: 2); precondition(!s.wantsAudio(now: 2))
    s.key(true, now: 3); s.key(false, now: 3.1)
    precondition(s.wantsAudio(now: 3.2))
    s.otherInput()
    precondition(!s.wantsAudio(now: 3.3), "Any key or click ends Doubao, so it ends tap-to-talk")
    s.key(true, now: 3.5); s.key(false, now: 3.6)
    precondition(s.wantsAudio(now: 3.7), "After that, the next Fn tap starts again instead of stopping")
    s.key(true, now: 4); precondition(!s.wantsAudio(now: 4))
    s.key(false, now: 4.1); precondition(!s.wantsAudio(now: 4.5))
    s.key(true, now: 5)
    s.remoteChanged(true, now: 5.05)
    precondition(!s.wantsAudio(now: 5.4))
    s.key(false, now: 6); s.remoteChanged(false, now: 7)
    precondition(!s.wantsAudio(now: 8))
    s.key(true, now: 9); s.key(false, now: 9.1)
    s.remoteChanged(true, now: 9.2); s.remoteChanged(false, now: 10)
    precondition(!s.wantsAudio(now: 11))
    s.key(true, now: 12); s.key(false, now: 12.1)
    s.otherInput()
    precondition(!s.wantsAudio(now: 12.2), "A physical key must stop tap-to-talk")
    var transition = Intent()
    transition.remoteChanged(true, now: 20)
    transition.remoteChanged(false, now: 21)
    transition.key(true, now: 21.1)
    precondition(transition.wantsAudio(now: 21.5), "Keyboard press during remote settling must not be lost")
    transition.key(false, now: 22)
    precondition(!transition.wantsAudio(now: 22))
    transition.remoteChanged(true, now: 23)
    transition.remoteChanged(false, now: 24)
    transition.key(true, now: 24.05); transition.key(false, now: 24.15)
    precondition(!transition.wantsAudio(now: 24.2))
    precondition(transition.wantsAudio(now: 24.5), "A short Fn tap during settling must be remembered")
    transition.key(true, now: 25); transition.key(false, now: 25.1)
    precondition(!transition.wantsAudio(now: 25.5), "Stop tap must not restart recording")
    var stuck = Intent()
    stuck.remoteChanged(true, now: 30)
    stuck.key(true, now: 40); precondition(!stuck.wantsAudio(now: 40.5), "Remote keeps priority while streaming")
    stuck.key(false, now: 41)
    stuck.key(true, now: 110)
    precondition(stuck.wantsAudio(now: 110.3), "A missing remote STOP must not lock out Fn")
    print("PASS: hold, tap toggle, stop, remote priority, no automatic resume, stale remote, any input ends tap")
}

func requireOK(_ status: OSStatus) throws {
    if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}

func deviceName(_ id: AudioDeviceID) throws -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var v: CFString = "" as CFString
    var n = UInt32(MemoryLayout<CFString>.size)
    try requireOK(withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(id, &a, 0, nil, &n, $0) })
    return v as String
}

func devices() throws -> [AudioDeviceID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var n: UInt32 = 0
    try requireOK(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n))
    var ids = [AudioDeviceID](repeating: 0, count: Int(n) / MemoryLayout<AudioDeviceID>.size)
    try requireOK(ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, $0.baseAddress!) })
    return ids
}

let mono = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

func bindToVirtualOutput(_ engine: AVAudioEngine) throws {
    guard var id = try devices().first(where: { try deviceName($0) == "MiRemoteV 2ch" }), let unit = engine.outputNode.audioUnit else {
        throw NSError(domain: "MicBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 MiRemoteV 2ch"])
    }
    try requireOK(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4))
}

func outputIsVirtual(_ engine: AVAudioEngine) throws -> Bool {
    guard let unit = engine.outputNode.audioUnit else { return false }
    var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try requireOK(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size))
    return try deviceName(id) == "MiRemoteV 2ch"
}

final class Bridge: NSObject, NSApplicationDelegate {
    var intent = Intent()
    var enabled = false
    var note: String?
    // Output binds to MiRemoteV 2ch on the first press and is released after a minute unused, so idle costs nothing
    // while back-to-back presses skip the device reconfiguration that SayAll and this app trip over.
    var engine: AVAudioEngine?
    var player: AVAudioPlayerNode?
    var configObserver: NSObjectProtocol?
    var capture: Capture?
    var preparing = false
    var generation = 0
    var startedAt: TimeInterval = 0
    var lastInputAt: TimeInterval = 0
    var lastPlayedAt: TimeInterval = 0
    var queuedFrames = 0
    var restarts: [TimeInterval] = []
    var timer: Timer?
    let audioQueue = DispatchQueue(label: "KeyboardMicBridge.audio", qos: .userInitiated)
    var hid: IOHIDManager?
    var tap: CFMachPort?
    var eventSource: CFRunLoopSource?
    var fnDown = false
    var logWatcher: DispatchSourceFileSystemObject?
    var logFile: FileHandle?
    let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteMic/runtime.log")
    var logBuffer = ""
    var logOffset: UInt64 = 0
    var logIdentity: UInt64 = 0
    var item: NSStatusItem!
    var statusLine: NSMenuItem!
    var toggleItem: NSMenuItem!
    var shown = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        statusLine = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        toggleItem = menu.addItem(withTitle: "Fn 语音", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(withTitle: "通道自检", action: #selector(testRoute), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(suspend), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(suspend), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        enableBridge()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { item.button?.performClick(nil); return false }
    func applicationWillTerminate(_ notification: Notification) { disableBridge(); audioQueue.sync {} }

    func refresh() {
        guard item != nil else { return }
        let symbol: String, text: String
        if !enabled { (symbol, text) = ("mic.slash", note ?? "已停用 · 不采集声音") }
        else if capture != nil || preparing { (symbol, text) = ("mic.fill", intent.latched ? "收音中 · 按 Fn 或任意键结束" : "收音中 · 松开 Fn 结束") }
        else if intent.remote { (symbol, text) = ("dot.radiowaves.left.and.right", "遥控器收音中") }
        else { (symbol, text) = ("mic", note ?? "待命 · 按住或点按 Fn 说话") }
        toggleItem.state = enabled ? .on : .off
        guard shown != symbol + text else { return }
        shown = symbol + text
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        item.button?.contentTintColor = symbol == "mic.fill" ? .systemRed : nil
        item.button?.toolTip = text
        statusLine.title = text
    }

    @objc func toggle() { enabled ? disableBridge() : enableBridge() }

    @objc func enableBridge() {
        guard !enabled else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && CGPreflightListenEventAccess() { activate(); return }
        let alert = NSAlert()
        alert.messageText = "用 Fn 让电脑麦克风接入豆包"
        alert.informativeText = "按住 Fn 说话，松开结束；点按 Fn 持续收音，再按 Fn、任意键或点鼠标结束（和豆包一致）。遥控器说话时自动让出。\n\n声音只转给 MiRemoteV 2ch，不录音、不联网。首次需允许「麦克风」和「输入监控」。"
        alert.addButton(withTitle: "启用"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            DispatchQueue.main.async {
                guard allowed else { self.note = "未允许麦克风：系统设置 › 隐私与安全性 › 麦克风"; self.refresh(); return }
                self.activate()
            }
        }
    }

    func activate() {
        guard !enabled else { return }
        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            note = "请在 系统设置 › 隐私与安全性 › 输入监控 允许后再启用"
            refresh(); return
        }
        // Keys come straight from keyboard hardware: system key events can be swallowed by Doubao
        // (seen 2026-11-11: Fn taps missing while its panel was up) and the Globe key adds a fake keyDown.
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            let b = Unmanaged<Bridge>.fromOpaque(context!).takeUnretainedValue()
            let e = IOHIDValueGetElement(value)
            b.hidKey(page: IOHIDElementGetUsagePage(e), usage: IOHIDElementGetUsage(e), pressed: IOHIDValueGetIntegerValue(value) != 0)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            note = "无法读取键盘，请检查输入监控权限"; refresh(); return
        }
        hid = m
        // Mouse clicks also end Doubao; they come from the event tap. Software-posted clicks carry a process id.
        let mask = CGEventMask([CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(0) { $0 | 1 << $1.rawValue })
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            let b = Unmanaged<Bridge>.fromOpaque(context!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = b.tap { CGEvent.tapEnable(tap: t, enable: true) }   // macOS pauses slow taps; resume
            } else if event.getIntegerValueField(.eventSourceUnixProcessID) == 0 {
                DispatchQueue.main.async { b.otherInput() }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            eventSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), eventSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        enabled = true; note = nil; intent = Intent(); fnDown = false
        watchLog()
        refresh()
    }

    @objc func disableBridge() {
        enabled = false
        stopCapture()
        dropOutput()
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        eventSource = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        if let hid { IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue); IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone)) }
        hid = nil
        logWatcher?.cancel(); logWatcher = nil; logFile = nil
        intent = Intent(); fnDown = false
        refresh()
    }

    @objc func suspend() { intent.cancel(); fnDown = false; stopCapture(); refresh() }

    // MARK: Keyboard and mouse

    func hidKey(page: UInt32, usage: UInt32, pressed: Bool) {
        if page == 0xFF && usage == 0x03 { fnChanged(pressed) }   // Apple top-case Fn / Globe key
        else if page == UInt32(kHIDPage_KeyboardOrKeypad) && (0x04...0xDF).contains(usage) && pressed { otherInput() }   // any non-modifier key
    }

    func fnChanged(_ down: Bool) {
        guard enabled, down != fnDown else { return }   // several HID interfaces may report the same key
        let now = uptime()
        pollLog()
        fnDown = down
        intent.key(down, now: now)
        if down {
            let delay = max(0.21, intent.blockedUntil - now + 0.01)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateAudio() }
        }
        updateAudio()
    }

    // Doubao ends on any other key or click, so tap mode ends with it.
    func otherInput() {
        guard enabled, intent.latched else { return }
        intent.otherInput()
        updateAudio()
    }

    // MARK: SayAll log (remote state)

    func watchLog() {
        logWatcher?.cancel(); logWatcher = nil; logFile = nil
        guard enabled else { return }
        guard let file = openLog() else {
            note = "读不到 SayAll 状态，遥控器避让暂停"
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if let self, self.enabled, self.logFile == nil { self.watchLog() }
            }
            return
        }
        let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: file.fileDescriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
        w.setEventHandler { [weak self] in
            guard let self, self.logFile === file else { return }
            // Log rotated or replaced: follow the new file instead of disabling.
            if !w.data.intersection([.delete, .rename, .revoke]).isEmpty { self.watchLog() } else { self.pollLog(); self.updateAudio() }
        }
        w.setCancelHandler { try? file.close() }
        logFile = file; logWatcher = w
        if note == "读不到 SayAll 状态，遥控器避让暂停" { note = nil }
        w.resume()
    }

    func openLog() -> FileHandle? {
        guard let file = try? FileHandle(forReadingFrom: logPath), let size = try? file.seekToEnd() else { return nil }
        try? file.seek(toOffset: size > 131072 ? size - 131072 : 0)
        let text = String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
        logOffset = (try? file.offset()) ?? size
        logIdentity = ((try? FileManager.default.attributesOfItem(atPath: logPath.path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        logBuffer = ""
        parse(text)
        return file
    }

    func parse(_ text: String) {
        for line in text.split(separator: "\n") {
            if line.contains("ATVV STREAM START session=") { intent.remoteChanged(true, now: uptime()) }
            else if line.contains("ATVV STREAM STOP session=") || line.contains("BLE DISCONNECTED") || line.contains("APP START") {
                intent.remoteChanged(false, now: uptime())
            }
        }
    }

    func pollLog() {
        // ponytail: SayAll 1.9.21 log strings are the only remote signal; version-coupled.
        guard enabled, let logFile else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path)
        let identity = (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        guard attrs != nil, identity == logIdentity, size >= logOffset else { watchLog(); return }
        guard size > logOffset, let data = try? logFile.read(upToCount: Int(size - logOffset)) else { return }
        logOffset += UInt64(data.count)
        logBuffer += String(decoding: data, as: UTF8.self)
        if let end = logBuffer.lastIndex(of: "\n") { parse(String(logBuffer[...end])); logBuffer.removeSubrange(...end) }
        if logBuffer.utf8.count > 65536 { logBuffer = "" }
    }

    // MARK: Audio

    func updateAudio() {
        guard enabled else { return }
        let now = uptime()
        if intent.wantsAudio(now: now) {
            if capture == nil && !preparing { startCapture(); return }
            if capture != nil {
                if let problem = healthProblem(now) { interrupt(problem); return }
            }
        } else if capture != nil || preparing {
            stopCapture()
        }
        refresh()
    }

    func healthProblem(_ now: TimeInterval) -> String? {
        if now - startedAt > 1800 { return "已连续收音 30 分钟，自动结束" }
        if now - lastInputAt > 3 { return "电脑麦克风没有数据，已停止 · 再按 Fn 重试" }
        if now - lastPlayedAt > 3 || engine?.isRunning != true { dropOutput(); return "虚拟通道没响应，已停止 · 再按 Fn 重试" }
        return nil
    }

    // Transient failures stop this recording only; the bridge stays enabled so the next Fn press retries.
    func interrupt(_ message: String) {
        intent.cancel(); stopCapture(); note = message; refresh()
    }

    func startOutput() {
        guard engine == nil else { return }
        let e = AVAudioEngine(), p = AVAudioPlayerNode()
        e.attach(p); e.connect(p, to: e.mainMixerNode, format: mono)
        engine = e; player = p; queuedFrames = 0
        // Observe before starting so a change during startup is not missed.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.outputChanged(e, p)
        }
        do {
            try bindToVirtualOutput(e)
            e.prepare(); try e.start(); p.play()
        } catch { dropOutput(); note = "虚拟通道不可用：\(error.localizedDescription)" }
    }

    // SayAll reconfigures MiRemoteV 2ch (often in ~1.2 s bursts), which stops our engine.
    // Idle: just let go and rebuild on the next press, so we never join that loop.
    // Recording: restart in place, at most 3 times per 10 s, and only if still bound to MiRemoteV 2ch.
    func outputChanged(_ e: AVAudioEngine, _ p: AVAudioPlayerNode) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.engine === e, !e.isRunning else { return }
            guard self.capture != nil || self.preparing else { self.dropOutput(); return }
            let now = uptime()
            self.restarts = self.restarts.filter { now - $0 < 10 } + [now]
            do {
                guard self.restarts.count <= 3, try outputIsVirtual(e) else { throw NSError(domain: "MicBridge", code: 11) }
                // Flush buffers queued before the reset; left in place they jam the player and nothing plays.
                p.stop(); try e.start(); p.play(); self.queuedFrames = 0; self.lastPlayedAt = now
            } catch { self.dropOutput(); self.interrupt("虚拟通道被重置，已停止 · 再按 Fn 重试") }
        }
    }

    func dropOutput() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        player?.stop(); engine?.stop()
        player = nil; engine = nil; queuedFrames = 0
    }

    func startCapture() {
        if let e = engine, !e.isRunning { dropOutput() }   // stopped without notice: rebuild
        if engine == nil { startOutput() }
        guard player != nil else { interrupt(note ?? "虚拟通道不可用"); return }
        preparing = true
        generation += 1
        let gen = generation
        refresh()
        audioQueue.async { [weak self] in
            do {
                let ids = try devices()
                guard let input = try ids.first(where: { try deviceName($0).contains("MacBook") && deviceName($0).contains("麦克风") }) else {
                    throw NSError(domain: "MicBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "找不到电脑麦克风"])
                }
                let c = try Capture(name: deviceName(input)) { buffer in
                    DispatchQueue.main.async { self?.play(buffer, gen) }
                }
                c.session.startRunning()
                guard c.session.isRunning else { throw NSError(domain: "MicBridge", code: 10, userInfo: [NSLocalizedDescriptionKey: "麦克风未能启动"]) }
                DispatchQueue.main.async {
                    guard let self, self.generation == gen, self.intent.wantsAudio(now: uptime()) else {
                        self?.audioQueue.async { c.session.stopRunning() }
                        if self?.generation == gen { self?.preparing = false; self?.refresh() }
                        return
                    }
                    self.preparing = false
                    self.capture = c
                    self.startedAt = uptime(); self.lastInputAt = self.startedAt; self.lastPlayedAt = self.startedAt
                    self.note = nil
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateAudio() }
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.interrupt("电脑麦克风启动失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func play(_ buffer: AVAudioPCMBuffer, _ gen: Int) {
        guard generation == gen else { return }
        lastInputAt = uptime()   // before the output check, so a dead output is reported as such
        guard let e = engine, let p = player, e.isRunning else { return }
        let frames = Int(buffer.frameLength)
        // Keep at most ~0.5 s queued; drop rather than grow. A stalled output is caught by healthProblem.
        guard queuedFrames + frames <= 8000 else { return }
        queuedFrames += frames
        p.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
                self.lastPlayedAt = uptime()
            }
        }
    }

    func stopCapture() {
        generation += 1
        preparing = false
        timer?.invalidate(); timer = nil
        let c = capture
        capture = nil
        audioQueue.async { c?.session.stopRunning() }
        let idle = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.generation == idle else { return }   // used again since: keep it
            self.dropOutput()
        }
    }

    // MARK: Self-test

    @objc func testRoute() {
        let wasEnabled = enabled
        disableBridge()
        do {
            let e = AVAudioEngine(), p = AVAudioPlayerNode()
            e.attach(p); e.connect(p, to: e.mainMixerNode, format: mono)
            try bindToVirtualOutput(e)
            let tone = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 16000)!
            tone.frameLength = 16000
            for n in 0..<16000 { tone.floatChannelData![0][n] = 0.05 * sin(2 * .pi * 440 * Float(n) / 16000) }
            var packets = 0
            var level: Float = 0
            let c = try Capture(name: "MiRemoteV 2ch") { buffer in
                var v: Float = 0
                if let data = buffer.floatChannelData { for n in 0..<Int(buffer.frameLength) { v = max(v, abs(data[0][n])) } }
                let measured = v
                DispatchQueue.main.async { packets += 1; level = max(level, measured) }
            }
            c.session.startRunning()
            try e.start(); p.scheduleBuffer(tone, at: nil); p.play()
            note = "自检中…（3 秒）"; refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                c.session.stopRunning(); p.stop(); e.stop()
                if wasEnabled { self?.activate() }
                self?.note = level > 0.005 ? "自检通过：虚拟通道收到测试音（\(packets) 包）" : "自检失败：虚拟通道没收到测试音"
                self?.refresh()
            }
        } catch {
            if wasEnabled { activate() }
            note = "自检失败：\(error.localizedDescription)"; refresh()
        }
    }
}

if CommandLine.arguments.contains("--self-test") { selfCheck(); exit(0) }
let app = NSApplication.shared
let bridge = Bridge()
app.delegate = bridge
app.run()
