// NotchBlob: a black overlay that sits exactly on the MacBook notch and, while you speak,
// swells outward a little in organic lumps, then settles back to the exact notch shape.
//
// Nothing is recorded or stored. Audio is analysed in memory and thrown away.

import AppKit
import AVFoundation
import Speech
import Accelerate

// MARK: - Tuning

enum Tune {
    /// How far the notch may grow at full voice, as a fraction of its own size.
    /// 0.10 per side means about 20% wider overall; the bottom may drop 40% of the notch height.
    static let sideGrow: CGFloat = 0.10
    static let bottomGrow: CGFloat = 0.40
    static let cornerRadius: CGFloat = 10      // the notch's lower corners
    static let margin: CGFloat = 60            // spare window room left and right of the notch
    static let below: CGFloat = 60             // spare window room under the notch
}

// MARK: - Finding the notch

struct NotchInfo {
    var rect: NSRect            // in global screen coordinates, origin bottom-left
    var screen: NSScreen
    var real: Bool
}

func findNotch() -> NotchInfo {
    let screens = NSScreen.screens
    if let s = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
        let h = s.safeAreaInsets.top
        let l = s.auxiliaryTopLeftArea?.width ?? (s.frame.width / 2 - 100)
        let r = s.auxiliaryTopRightArea?.width ?? (s.frame.width / 2 - 100)
        let w = s.frame.width - l - r
        return NotchInfo(rect: NSRect(x: s.frame.minX + l, y: s.frame.maxY - h, width: w, height: h), screen: s, real: true)
    }
    // no notch on this Mac: use a pill where one would be, so the effect can still be tried
    let s = NSScreen.main ?? screens[0]
    let w: CGFloat = 200, h: CGFloat = 32
    return NotchInfo(rect: NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h), screen: s, real: false)
}

// MARK: - Hearing a voice (not just a sound)

struct VoiceState {
    var active = false
    var level: Float = 0
    var bands = [Float](repeating: 0, count: 6)
    var snrDb: Float = 0
    var calibrating = true
}

final class VoiceAnalyzer {
    let engine = AVAudioEngine()
    private let lock = NSLock()
    private var shared = VoiceState()
    func read() -> VoiceState { lock.lock(); defer { lock.unlock() }; return shared }
    private func publish(_ s: VoiceState) { lock.lock(); shared = s; lock.unlock() }

    private let N = 1024, hop = 512
    private let log2n: vDSP_Length = 10
    private var fft: FFTSetup
    private var hann: [Float]
    private var ring: [Float] = []
    private var sampleRate = 48000.0
    private var seen = 0.0

    // detector state
    private let edges: [Double] = [120, 250, 500, 1000, 2000, 3500, 5500]
    private var floorP = 1e-12
    private var bandFloor = [Double](repeating: 1e-12, count: 6)
    private var active = false
    private var lastVoice = -9.0
    private var peakDb = 14.0
    private var calibStart: Double? = nil
    private var calibFrames = 0

    var running = false
    // called on the audio thread with every raw buffer; the wake-word listener taps in here
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    init() {
        fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        hann = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&hann, 1024, Int32(vDSP_HANN_NORM))
    }

    func start(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted { self.run() }
                done(self.running)
            }
        }
    }

    private func run() {
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        sampleRate = fmt.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in self?.process(buf) }
        do { try engine.start(); running = true } catch { running = false }
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        onBuffer?(buf)
        guard let ch = buf.floatChannelData else { return }
        ring.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        while ring.count >= N {
            analyze(Array(ring[0..<N]))
            ring.removeFirst(hop)
            seen += Double(hop)
        }
    }

    private func analyze(_ x: [Float]) {
        var w = [Float](repeating: 0, count: N)
        vDSP_vmul(x, 1, hann, 1, &w, 1, vDSP_Length(N))
        var re = [Float](repeating: 0, count: N / 2), im = [Float](repeating: 0, count: N / 2)
        var power = [Float](repeating: 0, count: N / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: N / 2) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(N / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(N / 2))
            }
        }

        let t = seen / sampleRate
        let hz = sampleRate / Double(N)
        let dtF = Double(hop) / sampleRate
        func rate(_ r: Double) -> Double { 1 - pow(1 - r, dtF / 0.0167) }   // same feel at any frame rate

        let b60 = max(1, Int(60 / hz)), b250 = Int(250 / hz), b3800 = min(N / 2 - 1, Int(3800 / hz))
        var speechP = 0.0, totalP = 0.0
        for i in b60..<(N / 2) {
            let p = Double(power[i])
            totalP += p
            if i >= b250 && i <= b3800 { speechP += p }
        }
        let ratio = speechP / (totalP + 1e-20)

        var bp = [Double](repeating: 0, count: 6)
        for j in 0..<6 {
            let a = max(1, Int((edges[j] / hz).rounded())), b = max(a + 1, Int((edges[j + 1] / hz).rounded()))
            var s = 0.0
            for i in a..<min(b, N / 2) { s += Double(power[i]) }
            bp[j] = s / Double(max(1, b - a))
        }

        // first 0.7 s: learn the room before judging anything
        if calibStart == nil { calibStart = t }
        if calibFrames < 8 || t - calibStart! < 0.7 {
            calibFrames += 1
            if calibFrames == 1 { floorP = speechP; bandFloor = bp }
            else {
                floorP += (speechP - floorP) * 0.3
                for j in 0..<6 { bandFloor[j] += (bp[j] - bandFloor[j]) * 0.3 }
            }
            publish(VoiceState(active: false, level: 0, bands: [Float](repeating: 0, count: 6), snrDb: 0, calibrating: true))
            return
        }

        // the floor falls fast and rises slowly, and never freezes
        let fr = speechP < floorP ? rate(0.2) : (active ? rate(0.0015) : rate(0.02))
        floorP = max(floorP + (speechP - floorP) * fr, 1e-13)
        let snrDb = 10 * log10((speechP + 1e-20) / floorP)

        let cand = active ? (snrDb > 3 && ratio > 0.12) : (snrDb > 6 && ratio > 0.2)
        if cand { lastVoice = t; active = true }
        else if t - lastVoice > 0.05 { active = false }

        peakDb = max(peakDb - 0.03 * dtF / 0.0167, snrDb, 14)
        let level = active ? pow(min(max((snrDb - 4) / (peakDb - 4), 0), 1), 0.6) : 0

        var bands = [Float](repeating: 0, count: 6)
        for j in 0..<6 {
            let br = bp[j] < bandFloor[j] ? rate(0.2) : (active ? rate(0.0015) : rate(0.02))
            bandFloor[j] = max(bandFloor[j] + (bp[j] - bandFloor[j]) * br, 1e-13)
            let db = 10 * log10((bp[j] + 1e-20) / bandFloor[j])
            bands[j] = active ? Float(min(max((db - 3) / 14, 0), 1)) : 0
        }
        publish(VoiceState(active: active, level: Float(level), bands: bands, snrDb: Float(snrDb), calibrating: false))
    }
}

// MARK: - The organic notch

func gauss() -> Double {          // a rough bell-shaped random number
    var s = 0.0
    for _ in 0..<4 { s += Double.random(in: -1...1) }
    return s / 2
}

final class NotchBlob {
    let N = 140
    let W: CGFloat, H: CGFloat, M: CGFloat, B: CGFloat
    var growth: CGFloat = 1

    private var base = [CGPoint](), nrm = [CGVector](), limit = [Double](), wt = [Double]()
    private var d: [Double], v: [Double], tgt: [Double], lap: [Double]
    private struct Lobe { var c: Double; var vc: Double; var sig: Double; var band: Int; var t: Double; var ph: Double; var fq: Double }
    private var prevEnv = 0.0, kickCool = 0.0
    private var wave = (k: 2.3, phase: 0.0, speed: 2.0, t: 1.0)
    private var lobes: [Lobe] = []
    private var acc = 0.0
    private let step = 1.0 / 120.0

    init(width: CGFloat, height: CGFloat) {
        W = width; H = height; M = Tune.margin; B = Tune.below
        d = [Double](repeating: 0, count: N); v = d; tgt = d; lap = d
        buildOutline()
        for j in 0..<7 {
            lobes.append(Lobe(c: (Double(j) + 0.5) / 7, vc: 0, sig: Double.random(in: 0.035...0.10), band: j % 6,
                              t: Double.random(in: 0...2), ph: Double.random(in: 0...6.28), fq: Double.random(in: 2...6)))
        }
    }

    /// The notch outline from its top-left down, round the bottom, and up to its top-right,
    /// resampled evenly so the springs behave the same everywhere.
    private func buildOutline() {
        let x0 = M, x1 = M + W, r = min(Tune.cornerRadius, H * 0.6)
        var pts = [CGPoint](), nr = [CGVector]()
        func add(_ p: CGPoint, _ n: CGVector) { pts.append(p); nr.append(n) }
        var y: CGFloat = 0
        while y < H - r { add(CGPoint(x: x0, y: y), CGVector(dx: -1, dy: 0)); y += 1 }
        for k in 0...12 {
            let th = CGFloat.pi - CGFloat(k) / 12 * (CGFloat.pi / 2)
            add(CGPoint(x: x0 + r + r * cos(th), y: H - r + r * sin(th)), CGVector(dx: cos(th), dy: sin(th)))
        }
        var x = x0 + r
        while x < x1 - r { add(CGPoint(x: x, y: H), CGVector(dx: 0, dy: 1)); x += 1 }
        for k in 0...12 {
            let th = CGFloat.pi / 2 - CGFloat(k) / 12 * (CGFloat.pi / 2)
            add(CGPoint(x: x1 - r + r * cos(th), y: H - r + r * sin(th)), CGVector(dx: cos(th), dy: sin(th)))
        }
        y = H - r
        while y >= 0 { add(CGPoint(x: x1, y: y), CGVector(dx: 1, dy: 0)); y -= 1 }

        var cum = [CGFloat](repeating: 0, count: pts.count)
        for i in 1..<pts.count { cum[i] = cum[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        let total = cum.last!
        var j = 0
        for i in 0..<N {
            let s = total * CGFloat(i) / CGFloat(N - 1)
            while j < pts.count - 2 && cum[j + 1] < s { j += 1 }
            let span = max(cum[j + 1] - cum[j], 0.0001), f = min(max((s - cum[j]) / span, 0), 1)
            let p = CGPoint(x: pts[j].x + (pts[j + 1].x - pts[j].x) * f, y: pts[j].y + (pts[j + 1].y - pts[j].y) * f)
            var n = CGVector(dx: nr[j].dx + (nr[j + 1].dx - nr[j].dx) * f, dy: nr[j].dy + (nr[j + 1].dy - nr[j].dy) * f)
            let nl = max(hypot(n.dx, n.dy), 0.0001); n = CGVector(dx: n.dx / nl, dy: n.dy / nl)
            base.append(p); nrm.append(n)
            // sides may grow sideways, the bottom may grow down; corners blend
            limit.append(Double(abs(n.dx) * W * Tune.sideGrow + abs(n.dy) * H * Tune.bottomGrow))
            // near the top edge the blob stays tucked in, so it reads as the notch swelling, not a stuck-on shape
            let tt = Double(min(max(p.y / 12, 0), 1))
            wt.append(0.3 + 0.7 * tt * tt * (3 - 2 * tt))
        }
    }

    func update(dt: Double, env: Double, bands: [Double]) {
        // each lump wanders along the outline on a smoothed velocity, and now and then follows a different part of the voice
        for i in lobes.indices {
            var l = lobes[i]
            l.vc = l.vc * exp(-2 * dt) + gauss() * (0.30 + 1.1 * env) * sqrt(dt)
            l.ph += l.fq * (0.6 + 1.2 * env) * dt
            l.c += l.vc * dt
            if l.c < 0.03 { l.c = 0.03; l.vc = abs(l.vc) } else if l.c > 0.97 { l.c = 0.97; l.vc = -abs(l.vc) }
            l.t -= dt
            if l.t < 0 {
                l.t = 1.2 + Double.random(in: 0...2.5)
                l.sig = Double.random(in: 0.035...0.11)
                l.fq = Double.random(in: 2...6)
                if Double.random(in: 0...1) < 0.5 { l.band = Int.random(in: 0..<6) }
            }
            lobes[i] = l
        }
        wave.t -= dt
        if wave.t < 0 { wave.t = 1.0 + Double.random(in: 0...2.5); wave.k = Double.random(in: 1.4...4.2); wave.speed = Double.random(in: -3.5...3.5) }
        wave.phase += wave.speed * (0.4 + env) * dt
        kickCool -= dt
        let rise = (env - prevEnv) / max(dt, 0.001)
        prevEnv = env
        if rise > 2.2 && kickCool <= 0 && env > 0.15 { kick(); kickCool = 0.18 }
        for i in 0..<N {
            let s = Double(i) / Double(N - 1)
            var sum = 0.12 * env
            for l in lobes {
                let z = (s - l.c) / l.sig
                sum += bands[l.band] * exp(-0.5 * z * z) * 1.7 * (0.6 + 0.4 * sin(l.ph))
            }
            sum += env * 0.28 * sin(wave.k * s * 6.2832 - wave.phase)      // a slow wave travelling the outline
            sum = max(sum, 0)
            let sat = (1 - exp(-1.8 * sum)) / 0.83
            tgt[i] = limit[i] * wt[i] * Double(growth) * min(sat, 1.0)
        }
        acc += dt
        var guardN = 0
        while acc >= step && guardN < 12 {
            guardN += 1; acc -= step
            integrate(&d, &v)
        }
    }

    /// A sudden start of a sound flicks a lump outward, and the ripple runs along the outline.
    private func kick() {
        let l = lobes[Int.random(in: 0..<lobes.count)]
        for i in 0..<N {
            let s = Double(i) / Double(N - 1), z = (s - l.c) / (l.sig * 1.4)
            v[i] += limit[i] * wt[i] * Double(growth) * exp(-0.5 * z * z) * 2.2
        }
    }

    // a lively spring toward the target, with neighbours dragging on each other: slow, oily, no bounce
    private func integrate(_ u: inout [Double], _ vel: inout [Double]) {
        let k = 210.0, c = 21.0, nu = 1200.0, visc = 14.0
        for i in 0..<N {
            let a = u[max(i - 1, 0)], b = u[min(i + 1, N - 1)]
            lap[i] = a + b - 2 * u[i]
        }
        for i in 0..<N { vel[i] += (k * (tgt[i] - u[i]) - c * vel[i] + nu * lap[i]) * step }
        for i in 0..<N {
            let a = vel[max(i - 1, 0)], b = vel[min(i + 1, N - 1)]
            lap[i] = a + b - 2 * vel[i]
        }
        for i in 0..<N {
            vel[i] += visc * lap[i] * step
            u[i] += vel[i] * step
            u[i] = min(max(u[i], 0), max(limit[i] * Double(growth) * 1.15, 0.0001))
        }
    }

    /// The outline as a path in the overlay's coordinates (origin bottom-left, y up).
    func path() -> CGPath {
        let viewH = H + B
        func P(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: viewH - p.y) }
        var pts = [CGPoint]()
        for i in 0..<N {
            pts.append(CGPoint(x: base[i].x + nrm[i].dx * CGFloat(d[i]), y: base[i].y + nrm[i].dy * CGFloat(d[i])))
        }
        let path = CGMutablePath()
        path.move(to: P(CGPoint(x: pts[0].x, y: -20)))             // starts above the screen edge so the top is always sealed
        path.addLine(to: P(pts[0]))
        for i in 1..<(N - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: P(mid), control: P(pts[i]))
        }
        path.addLine(to: P(pts[N - 1]))
        path.addLine(to: P(CGPoint(x: pts[N - 1].x, y: -20)))
        path.closeSubpath()
        return path
    }
}

// MARK: - The window

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // allowed to sit over the menu bar, where windows are normally pushed down
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - The app


// Listens for one word, entirely on this Mac. If the system can't recognise speech on-device,
// the option is refused rather than sending audio to Apple's servers.
final class WakeWord {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private(set) var listening = false
    let word: String
    var onWake: (() -> Void)?
    var onState: ((String) -> Void)?

    init(word: String) { self.word = word }

    var supported: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.onState?("speech recognition blocked: allow it in System Settings > Privacy & Security > Speech Recognition")
                    return
                }
                guard self.supported else {
                    self.onState?("this Mac can't recognise speech on-device, so the wake word is off")
                    return
                }
                self.listening = true
                self.begin()
            }
        }
    }

    func stop() {
        listening = false
        restartTimer?.invalidate(); restartTimer = nil
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        task?.cancel(); task = nil
    }

    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock(); request?.append(buf); lock.unlock()
    }

    // Recognition sessions are short-lived (about a minute), so roll a fresh one regularly.
    private func begin() {
        guard listening, let rec = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        lock.lock(); request?.endAudio(); request = req; lock.unlock()
        task?.cancel()
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let r = result, r.bestTranscription.formattedString.lowercased().contains(self.word) {
                DispatchQueue.main.async { self.onWake?() }
                // start clean so one utterance doesn't keep re-triggering
                DispatchQueue.main.async { if self.listening { self.begin() } }
                return
            }
            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self.listening { self.begin() } }
            }
        }
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            if self?.listening == true { self?.begin() }
        }
    }
}

final class Controller: NSObject, NSApplicationDelegate {
    var window: OverlayWindow!
    var shape = CAShapeLayer()
    var blob: NotchBlob!
    var notch: NotchInfo!
    let analyzer = VoiceAnalyzer()
    var timer: Timer?
    var statusItem: NSStatusItem!
    var statusLine = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
    var demo = CommandLine.arguments.contains("--demo")
    var micState = "asking for the microphone"
    var env = 0.0
    var bands = [Double](repeating: 0, count: 6)
    var last = CACurrentMediaTime()
    var clock = 0.0
    var growthItems: [NSMenuItem] = []
    var demoItem: NSMenuItem!
    // Optional wake word: when on, the notch stays still until you say "blob", then
    // follows your voice and goes back to sleep after a quiet stretch.
    let wake = WakeWord(word: "blob")
    var wakeItem: NSMenuItem!
    var wakeNowItem: NSMenuItem!
    var wakeEnabled = UserDefaults.standard.bool(forKey: "wakeWord")
    var awakeUntil = 0.0
    let awakeHold = 12.0
    var awake: Bool { clock < awakeUntil }
    // --snapshot <dir>: write a few frames of the overlay as PNGs, then quit. For checking the shape without screen-recording permission.
    var snapshotDir: String? = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count { return a[i + 1] }
        return nil
    }()
    var snapCount = 0
    var nextSnap = 2.0

    func snapshotIfDue(_ dir: String) {
        if clock < nextSnap { return }
        nextSnap += 1.6
        let size = window.frame.size, scale = 3
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.setFillColor(CGColor(red: 0.55, green: 0.62, blue: 0.72, alpha: 1))     // a stand-in menu bar colour
        ctx.fill(CGRect(origin: .zero, size: size))
        shape.render(in: ctx)
        if let img = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/frame\(snapCount).png"))
        }
        snapCount += 1
        if snapCount == 1 {
            print("notch rect: \(notch.rect)  real: \(notch.real)  window: \(window.frame)  env: \(env)")
        }
        if snapCount >= 6 { NSApp.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        buildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if !demo {
            analyzer.start { ok in
                self.micState = ok ? "listening" : "microphone blocked: allow it in System Settings > Privacy & Security > Microphone"
            }
        } else { micState = "demo voice" }
        analyzer.onBuffer = { [weak self] buf in self?.wake.feed(buf) }
        wake.onWake = { [weak self] in
            guard let self = self, self.wakeEnabled else { return }
            self.awakeUntil = self.clock + self.awakeHold
        }
        wake.onState = { [weak self] msg in
            self?.micState = msg
            self?.setWake(false)
        }
        if wakeEnabled { wake.start() }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func buildWindow() {
        window?.orderOut(nil)
        notch = findNotch()
        blob = NotchBlob(width: notch.rect.width, height: notch.rect.height)
        blob.growth = currentGrowth
        let w = notch.rect.width + 2 * Tune.margin, h = notch.rect.height + Tune.below
        let frame = NSRect(x: notch.rect.minX - Tune.margin, y: notch.screen.frame.maxY - h, width: w, height: h)
        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        shape = CAShapeLayer()
        shape.frame = view.bounds
        shape.fillColor = NSColor.black.cgColor
        shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        view.layer!.addSublayer(shape)
        window.contentView = view
        window.setFrame(frame, display: false)
        shape.path = blob.path()
        window.orderFrontRegardless()
    }

    // a small template blob, so the menu bar tints it for light and dark
    static func menuBarBlob() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let p = NSBezierPath()
            let n = 90
            for i in 0...n {
                let t = Double(i) / Double(n) * 2 * .pi
                let k = 1 + 0.13 * sin(2 * t + 0.6) + 0.09 * sin(3 * t + 2.1) + 0.05 * sin(5 * t + 4.0) + 0.04 * sin(t + 1.0)
                let pt = NSPoint(x: rect.midX + cos(t) * 6.4 * k, y: rect.midY + sin(t) * 6.4 * k * 0.94)
                i == 0 ? p.move(to: pt) : p.line(to: pt)
            }
            p.close(); NSColor.black.setFill(); p.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc func screensChanged() { buildWindow() }

    var currentGrowth: CGFloat = 1

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = Controller.menuBarBlob()
        }
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let g = NSMenuItem(title: "How far it grows", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, val) in [("Subtle", 0.6), ("Normal", 1.0), ("Bold", 1.5)] {
            let it = NSMenuItem(title: name, action: #selector(setGrowth(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = val
            it.state = val == 1.0 ? .on : .off
            sub.addItem(it); growthItems.append(it)
        }
        g.submenu = sub
        menu.addItem(g)
        demoItem = NSMenuItem(title: "Use a fake voice (test)", action: #selector(toggleDemo), keyEquivalent: "")
        demoItem.target = self
        demoItem.state = demo ? .on : .off
        menu.addItem(demoItem)
        wakeItem = NSMenuItem(title: "Only wake when I say “blob”", action: #selector(toggleWake), keyEquivalent: "")
        wakeItem.target = self
        wakeItem.state = wakeEnabled ? .on : .off
        menu.addItem(wakeItem)
        wakeNowItem = NSMenuItem(title: "Wake now", action: #selector(wakeNow), keyEquivalent: "")
        wakeNowItem.target = self
        menu.addItem(wakeNowItem)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
        statusItem.menu = menu
    }

    @objc func setGrowth(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        currentGrowth = CGFloat(v)
        blob.growth = currentGrowth
        for it in growthItems { it.state = (it === sender) ? .on : .off }
    }

    func setWake(_ on: Bool) {
        wakeEnabled = on
        UserDefaults.standard.set(on, forKey: "wakeWord")
        wakeItem.state = on ? .on : .off
        if on { wake.start() } else { wake.stop() }
    }

    @objc func toggleWake() { setWake(!wakeEnabled) }
    @objc func wakeNow() { awakeUntil = clock + awakeHold }

    @objc func toggleDemo() {
        demo.toggle()
        demoItem.state = demo ? .on : .off
        micState = demo ? "demo voice" : (analyzer.running ? "listening" : micState)
    }

    // a stand-in voice for trying it with no microphone
    func demoVoice(_ t: Double) -> (Double, [Double]) {
        let phrase = min(max(sin(2 * .pi * 0.13 * t + 1.0) * 3 + 0.8, 0), 1)
        let syl = pow(max(0, sin(2 * .pi * (2.6 + 0.7 * sin(2 * .pi * 0.11 * t)) * t)), 1.4)
        let raw = phrase * (0.25 + 0.75 * syl)
        let on = raw > 0.08
        var b = [Double]()
        for j in 0..<6 {
            let x = 0.6 + 0.6 * sin(t * (1.1 + Double(j) * 0.63) + Double(j) * 1.9) * sin(t * 0.37 + Double(j))
            b.append(on ? raw * min(max(x, 0), 1) : 0)
        }
        return (on ? raw : 0, b)
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - last, 0.05)
        last = now; clock += dt

        var level = 0.0
        var tb = [Double](repeating: 0, count: 6)
        var snr: Float = 0
        if demo {
            let (l, b) = demoVoice(clock); level = l; tb = b
        } else if analyzer.running {
            let v = analyzer.read()
            snr = v.snrDb
            if v.calibrating { micState = "learning the room: stay quiet a moment" }
            else {
                micState = "listening"
                level = v.active ? Double(v.level) : 0
                for j in 0..<6 { tb[j] = v.active ? Double(v.bands[j]) : 0 }
            }
        }
        // with the wake word on, a sleeping notch ignores the room; speech keeps it awake
        if wakeEnabled {
            if awake && level > 0 { awakeUntil = clock + awakeHold }
            if !awake { level = 0; tb = [Double](repeating: 0, count: 6) }
        }
        // quick to rise, a little slower to fall: tied to the voice but never twitchy
        let up = 1 - exp(-dt / 0.03), down = 1 - exp(-dt / 0.10)
        env += (level - env) * (level > env ? up : down)
        for j in 0..<6 { bands[j] += (tb[j] - bands[j]) * (tb[j] > bands[j] ? up : down) }

        blob.update(dt: dt, env: env, bands: bands)
        shape.path = blob.path()

        if let dir = snapshotDir { snapshotIfDue(dir) }
        let sleepNote = wakeEnabled ? (awake ? "  · awake" : "  · say “blob”") : ""
        statusLine.title = (demo ? "Demo voice" : "Mic: \(micState)" + (analyzer.running ? String(format: "  (%+.0f dB)", snr) : "")) + sleepNote
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
