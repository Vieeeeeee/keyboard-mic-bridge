import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia

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
    var stoppingTap = false
    var blockedUntil: TimeInterval = 0
    mutating func remoteChanged(_ active: Bool, now: TimeInterval) {
        remote = active
        downAt = nil
        latched = false
        stoppingTap = false
        blockedUntil = now + 0.4
    }
    mutating func key(_ down: Bool, now: TimeInterval) {
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
    mutating func otherKey(code: Int64) {
        // Process IDs do not reliably distinguish IME-injected typing; only Escape cancels.
        if code == 53 { latched = false }
    }
}

func selfCheck() {
    var s = Intent()
    s.key(true, now: 1); precondition(!s.wantsAudio(now: 1.1))
    precondition(s.wantsAudio(now: 1.25))
    s.key(false, now: 2); precondition(!s.wantsAudio(now: 2))
    s.key(true, now: 3); s.key(false, now: 3.1)
    precondition(s.wantsAudio(now: 3.2))
    s.otherKey(code: 0)
    precondition(s.wantsAudio(now: 3.3), "Transcribed text must not stop tap-to-talk")
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
    s.otherKey(code: 53)
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
    print("PASS: hold, tap toggle, stop, remote priority, no automatic resume")
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

final class Bridge: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var intent = Intent()
    var engine: AVAudioEngine?
    var captureEngine: Capture?
    var player: AVAudioPlayerNode?
    var tap: CFMachPort?
    var timer: Timer?
    var logWatcher: DispatchSourceFileSystemObject?
    var eventSource: CFRunLoopSource?
    let audioQueue = DispatchQueue(label: "KeyboardMicBridge.audio", qos: .userInitiated)
    var preparing = false
    var audioGeneration = 0
    var lastAudioAt: TimeInterval = 0
    var outstandingFrames: Int = 0
    var lastUIAt: TimeInterval = 0
    var item: NSStatusItem!
    var status: NSMenuItem!
    var window: NSWindow!
    let statusLabel = NSTextField(labelWithString: "未启用；不采集声音")
    var enabled = false
    var logFile: FileHandle?
    var logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteMic/runtime.log")
    var logBuffer = ""
    var logOffset: UInt64 = 0
    var logIdentity: UInt64 = 0
    var startedAt: TimeInterval?
    var capturedBuffers = 0
    var playedBuffers = 0
    var peak: Float = 0
    var fnDown = false
    var lastGesture = "等待 Fn"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "麦克风：停用"
        let menu = NSMenu()
        status = NSMenuItem(title: "未启用；不采集声音", action: nil, keyEquivalent: "")
        menu.addItem(status)
        let settings = NSMenuItem(title: "打开控制窗口", action: #selector(showWindow), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        let enable = NSMenuItem(title: "启用键盘语音兼容…", action: #selector(enableBridge), keyEquivalent: "")
        enable.target = self; menu.addItem(enable)
        let stop = NSMenuItem(title: "立即停止并停用", action: #selector(disableBridge), keyEquivalent: "")
        stop.target = self; menu.addItem(stop)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 270), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "键盘语音兼容测试"
        window.delegate = self
        window.isReleasedWhenClosed = false
        statusLabel.frame = NSRect(x: 24, y: 158, width: 412, height: 38)
        statusLabel.lineBreakMode = .byWordWrapping
        window.contentView?.addSubview(statusLabel)
        let instructions = NSTextField(wrappingLabelWithString: "保留 SayAll 和豆包。启用后，键盘 Fn 把电脑麦克风送入 MiRemoteV 2ch；遥控器收音优先。测试版，尚待实际出字验收。")
        instructions.frame = NSRect(x: 24, y: 72, width: 412, height: 72)
        window.contentView?.addSubview(instructions)
        let start = NSButton(title: "启用测试…", target: self, action: #selector(enableBridge))
        start.frame = NSRect(x: 24, y: 20, width: 150, height: 34)
        window.contentView?.addSubview(start)
        let stopButton = NSButton(title: "立即停止并停用", target: self, action: #selector(disableBridge))
        stopButton.frame = NSRect(x: 194, y: 20, width: 200, height: 34)
        window.contentView?.addSubview(stopButton)
        let testButton = NSButton(title: "虚拟麦克风通道自检（3秒）", target: self, action: #selector(testRoute))
        testButton.frame = NSRect(x: 24, y: 220, width: 310, height: 34)
        window.contentView?.addSubview(testButton)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspendAudio), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspendAudio), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    }

    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc func suspendAudio() { disableBridge() }
    func showStatus(_ message: String) {
        if status.title != message { status.title = message }
        if window.isVisible && statusLabel.stringValue != message { statusLabel.stringValue = message }
    }

    func applicationWillTerminate(_ notification: Notification) { disableBridge(); audioQueue.sync {} }

    @objc func enableBridge() {
        guard !enabled else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && CGPreflightListenEventAccess() {
            activate()
            return
        }
        let alert = NSAlert()
        alert.messageText = "启用键盘语音兼容测试版？"
        alert.informativeText = "按住 Fn 用电脑麦克风，短按 Fn 开始持续收音，再按 Fn 或 Esc 停止；其他按键不再停止本工具转发。声音仅转发给 MiRemoteV 2ch，不保存录音、不联网。遥控器收音时电脑收音停止。首次需允许麦克风及输入监控。当前为测试版，约 0.2 秒启动等待；尚需实际语音验收。"
        alert.addButton(withTitle: "启用"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            DispatchQueue.main.async {
                guard allowed else { self.fail("未允许麦克风，已停用"); return }
                self.activate()
            }
        }
    }

    func activate() {
        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            fail("请在系统设置允许输入监控，然后重新启用")
            return
        }
        guard openLog() else { fail("无法读取 SayAll 状态，已停用"); return }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            let b = Unmanaged<Bridge>.fromOpaque(context!).takeUnretainedValue()
            let now = ProcessInfo.processInfo.systemUptime
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let down = event.flags.contains(.maskSecondaryFn)
            // Audio startup can block; return from the event tap before touching audio or files.
            DispatchQueue.main.async { [b] in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    b.fail("按键监听被系统暂停，已停止收音；请重新启用")
                    return
                }
                guard b.enabled else { return }
                guard type == .flagsChanged || code == 53 else { return }
                b.pollLog()
                if type == .flagsChanged && code == 63 {
                    if down != b.fnDown {
                        b.fnDown = down
                        if !down, let start = b.intent.downAt {
                            b.lastGesture = "Fn \(Int((now - start) * 1000))ms"
                        }
                        b.intent.key(down, now: now)
                        if down {
                            let delay = max(0.21, b.intent.blockedUntil - now + 0.01)
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak b] in b?.updateAudio() }
                        }
                        b.showStatus(down ? "已收到 Fn 按下；正在准备收音" : "\(b.lastGesture)；持续模式 \(b.intent.latched ? "开" : "关")")
                    }
                } else if type == .keyDown && b.intent.latched {
                    b.intent.otherKey(code: code)
                }
                b.updateAudio()
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { fail("需要输入监控权限；授权后重新启用"); return }
        eventSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), eventSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        enabled = true
        if let logFile {
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: logFile.fileDescriptor, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
            watcher.setEventHandler { [weak self] in
                guard let self, let watcher = self.logWatcher else { return }
                if !watcher.data.intersection([.delete, .rename, .revoke]).isEmpty {
                    self.fail("SayAll 日志已更换；已安全停用，请重新启用")
                } else { self.pollLog(); self.updateAudio() }
            }
            logWatcher = watcher; watcher.resume()
        }
        item.button?.title = "麦克风：待命"
        showStatus("已启用；等待键盘 Fn（测试版）")
    }

    func openLog() -> Bool {
        do {
            let file = try FileHandle(forReadingFrom: logPath)
            let size = try file.seekToEnd()
            try file.seek(toOffset: size > 131072 ? size - 131072 : 0)
            let text = String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
            logFile = file; logOffset = size
            logIdentity = ((try FileManager.default.attributesOfItem(atPath: logPath.path)[.systemFileNumber]) as? NSNumber)?.uint64Value ?? 0
            logBuffer = ""
            intent = Intent()
            parse(text)
            return true
        } catch { return false }
    }

    func parse(_ text: String) {
        for line in text.split(separator: "\n") {
            let now = ProcessInfo.processInfo.systemUptime
            if line.contains("ATVV STREAM START session=") { intent.remoteChanged(true, now: now) }
            if line.contains("ATVV STREAM STOP session=") || line.contains("BLE DISCONNECTED") || line.contains("APP START") {
                intent.remoteChanged(false, now: now)
                fnDown = false
                if enabled && engine == nil && !preparing {
                    item.button?.title = "麦克风：待命"
                    showStatus("遥控器已结束；等待键盘 Fn")
                }
            }
        }
    }

    func pollLog() {
        // shortcut: SayAll 1.9.21 logs plus 200 ms settling, use device-specific events before daily use.
        guard enabled, let logFile else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: logPath.path)
            let identity = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            guard identity == logIdentity, size >= logOffset, size - logOffset < 1048576 else {
                fail("SayAll 日志轮换或状态不确定；请重新启用"); return
            }
            guard size > logOffset else { return }
            let data = try logFile.read(upToCount: Int(size - logOffset)) ?? Data()
            logOffset += UInt64(data.count)
            logBuffer += String(decoding: data, as: UTF8.self)
            if let end = logBuffer.lastIndex(of: "\n") {
                parse(String(logBuffer[...end])); logBuffer.removeSubrange(...end)
            }
            if logBuffer.utf8.count > 65536 { fail("状态日志异常，已停用") }
        } catch { fail("无法读取遥控器状态，已停用") }
    }

    func updateAudio() {
        guard enabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let startedAt, now - startedAt > 1800 { fail("本次已收音 30 分钟，已停止"); return }
        if intent.wantsAudio(now: now) {
            if engine == nil && !preparing { startAudio() }
            if engine != nil && now - lastUIAt >= 1 {
                lastUIAt = now
                if now - lastAudioAt > 3 { fail("麦克风已无数据，已安全停止"); return }
                if !engine!.isRunning { fail("虚拟输出已停止，已安全停止"); return }
                showStatus("\(intent.latched ? "点按持续收音中" : "按住收音中") · Fn／Esc 停止")
            }
        } else if engine != nil || preparing {
            stopAudio()
            item.button?.title = "麦克风：待命"
            showStatus(intent.remote ? "遥控器正在收音；电脑麦克风已停止" : "\(lastGesture)；输入包 \(capturedBuffers)，峰值 \(String(format: "%.4f", peak))，播放 \(playedBuffers)")
        }
    }

    func startAudio() {
        preparing = true
        audioGeneration += 1
        let generation = audioGeneration
        capturedBuffers = 0; playedBuffers = 0; peak = 0; outstandingFrames = 0
        showStatus("正在准备电脑麦克风…")
        audioQueue.async { [weak self] in
            guard let self else { return }
            var outputEngine: AVAudioEngine?
            var source: Capture?
            do {
                let ids = try devices()
                guard let input = try ids.first(where: { try deviceName($0).contains("MacBook") && deviceName($0).contains("麦克风") }),
                      let output = try ids.first(where: { try deviceName($0) == "MiRemoteV 2ch" }), input != output else {
                    throw NSError(domain: "MicBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有找到电脑麦克风或 MiRemoteV 2ch"])
                }
                let e = AVAudioEngine(), p = AVAudioPlayerNode()
                outputEngine = e
                let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                e.attach(p); e.connect(p, to: e.mainMixerNode, format: format)
                var outputID = output
                guard let unit = e.outputNode.audioUnit else { throw NSError(domain: "MicBridge", code: 2) }
                try requireOK(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputID, 4))
                let capture = try Capture(name: deviceName(input)) { [weak self] buffer in
                    DispatchQueue.main.async {
                        guard let self, self.audioGeneration == generation, self.engine === e, e.isRunning else { return }
                        let frames = Int(buffer.frameLength)
                        // Keep at most 250 ms queued; fail visibly instead of growing memory or dropping speech.
                        guard self.outstandingFrames + frames <= 4000 else {
                            self.fail("音频输出积压，已停止；请重新启用")
                            return
                        }
                        self.capturedBuffers += 1
                        self.lastAudioAt = ProcessInfo.processInfo.systemUptime
                        self.outstandingFrames += frames
                        p.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                            DispatchQueue.main.async {
                                guard let self, self.audioGeneration == generation else { return }
                                self.playedBuffers += 1
                                self.outstandingFrames = max(0, self.outstandingFrames - frames)
                            }
                        }
                    }
                }
                source = capture
                e.prepare(); try e.start(); p.play()
                capture.session.startRunning()
                guard capture.session.isRunning else { throw NSError(domain: "MicBridge", code: 10) }
                DispatchQueue.main.async { [self] in
                    guard self.enabled, self.audioGeneration == generation,
                          self.intent.wantsAudio(now: ProcessInfo.processInfo.systemUptime) else {
                        self.audioQueue.async { capture.session.stopRunning(); p.stop(); e.stop() }
                        return
                    }
                    self.preparing = false
                    self.engine = e; self.captureEngine = capture; self.player = p
                    self.startedAt = ProcessInfo.processInfo.systemUptime
                    self.lastAudioAt = self.startedAt!
                    self.item.button?.title = "● 收音中"
                    self.showStatus(self.intent.latched ? "点按持续收音中 · Fn／Esc 停止" : "按住收音中")
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateAudio() }
                }
            } catch {
                source?.session.stopRunning(); outputEngine?.stop()
                DispatchQueue.main.async {
                    guard self.audioGeneration == generation else { return }
                    self.fail("声音转发失败：\(error.localizedDescription)")
                }
            }
        }
    }

    @objc func testRoute() {
        disableBridge()
        var stage = "查找设备"
        do {
            let ids = try devices()
            guard let virtual = try ids.first(where: { try deviceName($0) == "MiRemoteV 2ch" }) else { throw NSError(domain: "MicBridge", code: 4) }
            let output = AVAudioEngine(), p = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            tone.frameLength = 16000
            for n in 0..<16000 { tone.floatChannelData![0][n] = 0.05 * sin(2 * .pi * 440 * Float(n) / 16000) }
            output.attach(p); output.connect(p, to: output.mainMixerNode, format: format)
            var id = virtual
            guard let ou = output.outputNode.audioUnit else { throw NSError(domain: "MicBridge", code: 2) }
            stage = "绑定虚拟输出"
            try requireOK(AudioUnitSetProperty(ou, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4))
            var actualOut: AudioDeviceID = 0, size: UInt32 = 4
            try requireOK(AudioUnitGetProperty(ou, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actualOut, &size))
            guard actualOut == virtual else { throw NSError(domain: "MicBridge", code: 5) }
            capturedBuffers = 0; peak = 0
            let input = try Capture(name: "MiRemoteV 2ch") { [weak self] buffer in
                var value: Float = 0
                if let data = buffer.floatChannelData {
                    for n in 0..<Int(buffer.frameLength) { value = max(value, abs(data[0][n])) }
                }
                let measured = value
                DispatchQueue.main.async { self?.capturedBuffers += 1; self?.peak = max(self?.peak ?? 0, measured) }
            }
            engine = output; captureEngine = input; player = p
            stage = "启动虚拟输入"
            input.session.startRunning()
            guard input.session.isRunning else { throw NSError(domain: "MicBridge", code: 10) }
            stage = "启动虚拟输出"
            try output.start()
            p.scheduleBuffer(tone, at: nil); p.play()
            showStatus("自检中：测试音只送往 MiRemoteV 2ch")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak output] in
                guard let self, let output, self.engine === output else { return }
                let packets = self.capturedBuffers, level = self.peak
                self.stopAudio()
                self.showStatus("自检\(level > 0.005 ? "通过" : "失败")：虚拟输入包 \(packets)，峰值 \(String(format: "%.4f", level))")
            }
        } catch { fail("\(stage)失败：\(error.localizedDescription)") }
    }

    @objc func disableBridge() {
        enabled = false
        timer?.invalidate(); timer = nil
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        eventSource = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        logWatcher?.cancel(); logWatcher = nil
        stopAudio()
        try? logFile?.close(); logFile = nil
        intent = Intent()
        fnDown = false
        item?.button?.title = "麦克风：停用"
        if status != nil { showStatus("已停用；不采集声音") }
    }
    func stopAudio() {
        audioGeneration += 1
        preparing = false
        timer?.invalidate(); timer = nil
        let capture = captureEngine, p = player, e = engine
        captureEngine = nil; player = nil; engine = nil; startedAt = nil
        outstandingFrames = 0
        audioQueue.async { capture?.session.stopRunning(); p?.stop(); e?.stop() }
    }
    func fail(_ message: String) { disableBridge(); showStatus(message) }
}

if CommandLine.arguments.contains("--self-test") { selfCheck(); exit(0) }
let app = NSApplication.shared
let bridge = Bridge()
app.delegate = bridge
app.run()
