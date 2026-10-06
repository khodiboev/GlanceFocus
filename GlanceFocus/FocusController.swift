import AppKit
import AVFoundation
import Vision
import Combine

struct DisplayInfo {
    let id: CGDirectDisplayID
    let bounds: CGRect   // global koordinatalar, chap-yuqori burchak = (0,0)
}

/// Sakrash tezligi: tezroq = sezgirroq, lekin tasodifiy sakrashlar ehtimoli ko'proq
enum Speed: String, CaseIterable, Identifiable {
    case slow, medium, fast, predictive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow: return "Sekin (eng barqaror)"
        case .medium: return "O'rta"
        case .fast: return "Tez"
        case .predictive: return "Juda tez (bashoratli)"
        }
    }

    struct Params {
        let fps: Double        // sekundiga nechta kadr tahlil qilinadi
        let smooth: Int        // signal nechta kadr bo'yicha o'rtachalanadi
        let stable: Double     // nigoh shuncha soniya barqaror bo'lsa sakraydi
        let idle: Double       // sichqoncha shuncha soniya tinch tursa sakraydi
        let predict: Bool      // bosh burilishini oldindan sezib sakrash
    }

    var params: Params {
        switch self {
        case .slow:       return Params(fps: 15, smooth: 5, stable: 0.35, idle: 0.6,  predict: false)
        case .medium:     return Params(fps: 30, smooth: 3, stable: 0.18, idle: 0.4,  predict: false)
        case .fast:       return Params(fps: 30, smooth: 2, stable: 0.08, idle: 0.25, predict: false)
        case .predictive: return Params(fps: 30, smooth: 2, stable: 0.08, idle: 0.25, predict: true)
        }
    }
}

final class FocusController: NSObject, ObservableObject {

    // MARK: - UI holati (main thread)

    @Published var statusText = "Ishga tushmoqda…"

    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }

    @Published var rememberPosition: Bool = UserDefaults.standard.bool(forKey: Keys.remember) {
        didSet {
            UserDefaults.standard.set(rememberPosition, forKey: Keys.remember)
            let value = rememberPosition
            videoQueue.async { self.t.rememberPosition = value }
        }
    }

    @Published var speed: Speed = Speed(rawValue: UserDefaults.standard.string(forKey: Keys.speed) ?? "") ?? .fast {
        didSet {
            UserDefaults.standard.set(speed.rawValue, forKey: Keys.speed)
            let params = speed.params
            videoQueue.async {
                self.t.params = params
                self.t.buffer.removeAll()
                self.t.history.removeAll()
            }
        }
    }

    @Published private(set) var isCalibrating = false

    private enum Keys {
        static let enabled = "enabled"
        static let remember = "rememberPosition"
        static let centers = "centers"
        static let speed = "speed"
    }

    // MARK: - Sozlamalar

    // Tezlik bilan bog'liq sozlamalar Speed enum ichida (menyudan tanlanadi)

    // Bashorat "murvatlari" — keraksiz sakrashlar bo'lsa, shu 4 ta raqamni oshiring
    private let predictMinProgress = 0.55   // bosh yo'lning kamida 55% ini bosib o'tishi kerak
    private let predictSpeedFactor = 1.8    // burilish tezligi: butun yo'lni ~0.55 s da bosib o'tadigan darajada
    private let predictFrames = 3           // shart ketma-ket shuncha kadr bajarilishi kerak (~0.1 s)
    private let predictCooldown = 0.4       // ikki bashorat orasidagi minimal tanaffus (soniya)
    private let calibrationSeconds: UInt64 = 2

    // MARK: - Kamera va monitorlar (main thread)

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "glancefocus.video")
    private var cameraReady = false
    private var displays: [DisplayInfo] = []
    private var centers: [Double?] = []

    // MARK: - Kuzatuv holati (faqat videoQueue ichida ishlatiladi)

    private struct TrackingState {
        var displays: [DisplayInfo] = []
        var centers: [Double] = []
        var hysteresis = 3.0
        var rememberPosition = false
        var params = Speed.fast.params
        var calibrating = false
        var calibrationSamples: [Double]? = nil
        var buffer: [Double] = []
        var candidate: Int? = nil
        var candidateSince = 0.0
        var lastMouse = CGPoint.zero
        var lastMouseMove = 0.0
        var lastFrame = 0.0
        var lastPositions: [CGDirectDisplayID: CGPoint] = [:]
        var history: [(time: Double, value: Double)] = []   // bashorat uchun so'nggi signallar
        var lastPredictiveJump = 0.0
        var predictCandidate: Int? = nil
        var predictStreak = 0
    }
    private var t = TrackingState()

    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3   // uzluksiz yaw/pitch/roll
        return r
    }()

    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3    // ko'z qorachig'i nuqtalari
        return r
    }()

    // MARK: - Hayot sikli

    override init() {
        super.init()
        t.rememberPosition = rememberPosition
        t.params = speed.params
        reloadDisplays()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Uyqu / qulf paytida kamerani o'chiramiz (maxfiylik + batareya)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(pause), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(resume), name: NSWorkspace.didWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(pause), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(resume), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        if isEnabled { start() } else { updateStatus() }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if !cameraReady { setupCamera() }
            runSession(true)
            // Birinchi ishga tushishda kalibratsiya avtomatik boshlanadi
            if cameraReady, displays.count >= 2, centers.contains(where: { $0 == nil }) {
                startCalibration()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { self.start() }
            }
        default:
            break
        }
        updateStatus()
    }

    private func stop() {
        runSession(false)
        updateStatus()
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        cameraReady = true
    }

    private func runSession(_ on: Bool) {
        guard cameraReady else { return }
        videoQueue.async {
            if on && !self.session.isRunning { self.session.startRunning() }
            if !on && self.session.isRunning { self.session.stopRunning() }
        }
    }

    @objc private func pause() { runSession(false) }
    @objc private func resume() { if isEnabled { runSession(true) } }
    @objc private func screensChanged() { reloadDisplays() }

    // MARK: - Monitorlar

    private func reloadDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        displays = ids.prefix(Int(count)).map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0)) }
        let saved = UserDefaults.standard.dictionary(forKey: Keys.centers) as? [String: Double] ?? [:]
        centers = displays.map { saved[String($0.id)] }

        pushStateToVideoQueue()
        updateStatus()
    }

    private func pushStateToVideoQueue() {
        let ds = displays
        let cs = centers.compactMap { $0 }
        let ready = ds.count >= 2 && cs.count == ds.count

        var gap = Double.infinity
        for i in 0..<cs.count {
            for j in (i + 1)..<cs.count { gap = min(gap, abs(cs[i] - cs[j])) }
        }
        let hysteresis = gap.isFinite ? max(3.0, gap * 0.15) : 3.0

        videoQueue.async {
            self.t.displays = ready ? ds : []
            self.t.centers = ready ? cs : []
            self.t.hysteresis = hysteresis
            self.t.buffer.removeAll()
            self.t.history.removeAll()
            self.t.predictStreak = 0
            self.t.candidate = nil
        }
    }

    private func updateStatus() {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .denied || auth == .restricted {
            statusText = "Kameraga ruxsat yo'q → System Settings › Privacy › Camera"
        } else if auth == .authorized && !cameraReady {
            statusText = "Kamera topilmadi"
        } else if !isEnabled {
            statusText = "O'chirilgan"
        } else if isCalibrating {
            statusText = "Kalibrlanmoqda…"
        } else if displays.count < 2 {
            statusText = "Kutilmoqda: 2-monitor ulanmagan"
        } else if centers.contains(where: { $0 == nil }) {
            statusText = "Kalibrlash kerak"
        } else {
            statusText = "Ishlayapti — \(displays.count) ta monitor"
        }
    }

    // MARK: - Kalibratsiya

    func startCalibration() {
        guard !isCalibrating else { return }
        reloadDisplays()
        guard displays.count >= 2 else { statusText = "Kamida 2 ta monitor kerak"; return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { updateStatus(); return }

        isCalibrating = true
        if !isEnabled { isEnabled = true } else { if !cameraReady { setupCamera() }; runSession(true) }
        guard cameraReady else { isCalibrating = false; updateStatus(); return }
        updateStatus()

        videoQueue.async { self.t.calibrating = true }
        let targets = displays

        Task { @MainActor in
            var result: [String: Double] = [:]
            var failed = false

            for d in targets {
                let overlay = CalibrationOverlay(displayID: d.id)
                self.warp(to: CGPoint(x: d.bounds.midX, y: d.bounds.midY))

                for n in stride(from: 3, through: 1, by: -1) {
                    overlay.setText("Qizil nuqtaga qarang\n\(n)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }

                overlay.setText("Qarab turing…")
                self.videoQueue.sync { self.t.calibrationSamples = [] }
                try? await Task.sleep(nanoseconds: self.calibrationSeconds * 1_000_000_000)
                let samples: [Double] = self.videoQueue.sync {
                    let s = self.t.calibrationSamples ?? []
                    self.t.calibrationSamples = nil
                    return s
                }
                overlay.close()

                if samples.count < 10 { failed = true; break }
                result[String(d.id)] = Self.median(samples)
            }

            if !failed {
                var saved = UserDefaults.standard.dictionary(forKey: Keys.centers) as? [String: Double] ?? [:]
                saved.merge(result) { _, new in new }
                UserDefaults.standard.set(saved, forKey: Keys.centers)
            }

            self.videoQueue.async { self.t.calibrating = false }
            self.isCalibrating = false
            self.reloadDisplays()
            if failed {
                self.statusText = "Yuz ko'rinmadi — yorug'likni tekshirib, qayta kalibrlang"
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s[s.count / 2]
    }

    // MARK: - Sichqoncha

    private func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)   // warp'dan keyin kursor qotib qolmasin
    }

    // MARK: - Nigoh signali (videoQueue)

    /// Bosh burilishi (gradus) + ko'z qorachig'i siljishi. Yuz yo'q bo'lsa nil.
    private func measure(_ pixelBuffer: CVPixelBuffer) -> Double? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest, landmarksRequest])
        } catch {
            return nil
        }

        guard let face = faceRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let yaw = face.yaw?.doubleValue else { return nil }

        var signal = yaw * 180 / .pi
        if let landmarks = landmarksRequest.results?
                .max(by: { $0.boundingBox.width < $1.boundingBox.width })?.landmarks,
           let offset = pupilOffset(landmarks) {
            signal += offset * 40
        }
        return signal
    }

    /// Qorachiq ko'z ichida qayerda: -0.5 (bir chet) … +0.5 (boshqa chet)
    private func pupilOffset(_ lm: VNFaceLandmarks2D) -> Double? {
        func ratio(_ eye: VNFaceLandmarkRegion2D?, _ pupil: VNFaceLandmarkRegion2D?) -> Double? {
            guard let eye, let pupil, let p = pupil.normalizedPoints.first else { return nil }
            let xs = eye.normalizedPoints.map { Double($0.x) }
            guard let lo = xs.min(), let hi = xs.max(), hi - lo > 0.001 else { return nil }
            return (Double(p.x) - lo) / (hi - lo)
        }
        let rs = [ratio(lm.leftEye, lm.leftPupil), ratio(lm.rightEye, lm.rightPupil)].compactMap { $0 }
        guard !rs.isEmpty else { return nil }
        return rs.reduce(0, +) / Double(rs.count) - 0.5
    }

    private func track(signal: Double?, now: Double) {
        guard t.displays.count >= 2 else { return }

        // Foydalanuvchi sichqonchani o'zi qimirlatyaptimi?
        let mouse = CGEvent(source: nil)?.location ?? .zero
        if hypot(mouse.x - t.lastMouse.x, mouse.y - t.lastMouse.y) > 2 {
            t.lastMouseMove = now
            t.lastMouse = mouse
        }
        let current = t.displays.firstIndex { $0.bounds.contains(mouse) }
        if let current { t.lastPositions[t.displays[current].id] = mouse }

        guard let signal else {
            t.candidate = nil
            t.buffer.removeAll()
            t.history.removeAll()
            t.predictStreak = 0
            return
        }

        t.history.append((time: now, value: signal))
        t.history.removeAll { now - $0.time > 0.25 }

        t.buffer.append(signal)
        if t.buffer.count > t.params.smooth { t.buffer.removeFirst() }
        let avg = t.buffer.reduce(0, +) / Double(t.buffer.count)

        // Eng yaqin kalibratsiya qiymati + gisterezis (titrashga qarshi)
        let dists = t.centers.map { abs(avg - $0) }
        guard var target = dists.indices.min(by: { dists[$0] < dists[$1] }) else { return }
        if let current, target != current, dists[current] - dists[target] < t.hysteresis {
            target = current
        }

        // Bashorat: bosh boshqa monitor tomon tez va ishonchli burilyapti
        if t.params.predict, let current,
           now - t.lastMouseMove >= t.params.idle,
           now - t.lastPredictiveJump >= predictCooldown {
            if let predicted = predictedTarget(current: current, signal: avg, now: now) {
                if predicted == t.predictCandidate {
                    t.predictStreak += 1
                } else {
                    t.predictCandidate = predicted
                    t.predictStreak = 1
                }
                // Bitta tasodifiy "sakrash"ga emas, ketma-ket bir necha kadrga ishonamiz
                if t.predictStreak >= predictFrames {
                    jump(to: predicted)
                    t.lastPredictiveJump = now
                    t.predictStreak = 0
                    t.predictCandidate = nil
                    t.candidate = predicted
                    t.candidateSince = now
                    return
                }
            } else {
                t.predictStreak = 0
                t.predictCandidate = nil
            }
        }

        // Barqarorlik: bir xil qaror params.stable soniya davom etishi kerak
        if target != t.candidate {
            t.candidate = target
            t.candidateSince = now
            return
        }
        guard now - t.candidateSince >= t.params.stable,
              target != current,
              now - t.lastMouseMove >= t.params.idle else { return }

        jump(to: target)
    }

    /// Sichqonchani tanlangan monitorga o'tkazadi (videoQueue)
    private func jump(to index: Int) {
        let d = t.displays[index]
        let point = (t.rememberPosition ? t.lastPositions[d.id] : nil)
            ?? CGPoint(x: d.bounds.midX, y: d.bounds.midY)
        warp(to: point)
        t.lastMouse = point
    }

    /// Bosh qaysi monitor tomon tez burilayotganini aniqlaydi. Aniq bo'lmasa nil.
    private func predictedTarget(current: Int, signal: Double, now: Double) -> Int? {
        // So'nggi 0.15 soniyadagi nuqtalar bo'yicha "eng yaxshi to'g'ri chiziq" qiyaligi = tezlik.
        // Ikki nuqta orasidagi farqdan ko'ra ancha barqaror: ko'zning tez pirpirashi kabi
        // bitta shovqinli kadr natijani buzmaydi.
        let window = t.history.filter { now - $0.time <= 0.15 }
        guard window.count >= 4 else { return nil }
        let n = Double(window.count)
        let meanT = window.reduce(0) { $0 + $1.time } / n
        let meanV = window.reduce(0) { $0 + $1.value } / n
        var num = 0.0, den = 0.0
        for p in window {
            num += (p.time - meanT) * (p.value - meanV)
            den += (p.time - meanT) * (p.time - meanT)
        }
        guard den > 0 else { return nil }
        let velocity = num / den   // birlik/soniya

        let start = t.centers[current]
        for j in t.centers.indices where j != current {
            let span = t.centers[j] - start
            guard abs(span) > 1 else { continue }

            let progress = (signal - start) / span                // 0 = joriy monitor, 1 = maqsad
            let towardSpeed = span > 0 ? velocity : -velocity      // maqsad tomon tezlik
            let minSpeed = max(30.0, abs(span) * predictSpeedFactor)

            if progress >= predictMinProgress, progress < 1.5, towardSpeed >= minSpeed {
                return j
            }
        }
        return nil
    }
}

// MARK: - Kamera kadrlari

extension FocusController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - t.lastFrame >= 1.0 / t.params.fps - 0.005 else { return }
        t.lastFrame = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let signal = measure(pixelBuffer)

        if t.calibrationSamples != nil {
            if let signal { t.calibrationSamples?.append(signal) }
            return
        }
        if t.calibrating { return }

        track(signal: signal, now: now)
    }
}
