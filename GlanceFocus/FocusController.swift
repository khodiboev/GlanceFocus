import AppKit
import AVFoundation
import Vision
import Combine

struct DisplayInfo {
    let id: CGDirectDisplayID
    let bounds: CGRect   // global coordinates, top-left corner = (0,0)
}

/// Reaction speed: faster = more responsive, but more likely to jump by accident
enum Speed: String, CaseIterable, Identifiable {
    case slow, medium, fast, predictive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow: return "Slow (most stable)"
        case .medium: return "Medium"
        case .fast: return "Fast"
        case .predictive: return "Very fast (predictive)"
        }
    }

    struct Params {
        let fps: Double        // camera frames analyzed per second
        let smooth: Int        // number of frames the signal is averaged over
        let stable: Double     // gaze must stay stable this long (s) before switching
        let idle: Double       // mouse must be idle this long (s) before the cursor moves
        let predict: Bool      // switch early when a head turn is detected
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

    // MARK: - UI state (main thread)

    @Published var statusText = "Starting…"

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

    @Published var moveCursor: Bool = UserDefaults.standard.object(forKey: Keys.moveCursor) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(moveCursor, forKey: Keys.moveCursor)
            let value = moveCursor
            videoQueue.async { self.t.moveCursor = value }
        }
    }

    @Published var frostEnabled: Bool = UserDefaults.standard.object(forKey: Keys.frost) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(frostEnabled, forKey: Keys.frost)
            let value = frostEnabled
            if !value { frostOverlay.hideAll() }
            videoQueue.async {
                self.t.frost = value
                // When turned on, immediately frost every screen except the one you're looking at
                if value, let gaze = self.t.gaze, gaze < self.t.displays.count {
                    let id = self.t.displays[gaze].id
                    DispatchQueue.main.async { self.frostOverlay.focus(on: id) }
                }
            }
        }
    }

    @Published private(set) var isCalibrating = false

    private enum Keys {
        static let enabled = "enabled"
        static let remember = "rememberPosition"
        static let centers = "centers"
        static let speed = "speed"
        static let moveCursor = "moveCursor"
        static let frost = "frostEnabled"
    }

    // MARK: - Settings

    // Speed-related settings live in the Speed enum (chosen from the menu)

    // Prediction tuning: if you get unwanted jumps, increase these four values
    private let predictMinProgress = 0.55   // head must have covered at least 55% of the way
    private let predictSpeedFactor = 1.8    // turn speed: fast enough to cover the whole way in ~0.55 s
    private let predictFrames = 3           // condition must hold for this many frames in a row (~0.1 s)
    private let predictCooldown = 0.4       // minimum pause between two predictions (s)
    private let calibrationSeconds: UInt64 = 2

    // MARK: - Camera and displays (main thread)

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "glancefocus.video")
    private var cameraReady = false
    private var displays: [DisplayInfo] = []
    private var centers: [Double?] = []
    private let frostOverlay = FrostOverlay()

    // MARK: - Tracking state (only used on videoQueue)

    private struct TrackingState {
        var displays: [DisplayInfo] = []
        var centers: [Double] = []
        var hysteresis = 3.0
        var rememberPosition = false
        var params = Speed.fast.params
        var moveCursor = true
        var frost = true
        var gaze: Int? = nil                 // the screen you're looking at (stable decision)
        var calibrating = false
        var calibrationSamples: [Double]? = nil
        var buffer: [Double] = []
        var candidate: Int? = nil
        var candidateSince = 0.0
        var lastMouse = CGPoint.zero
        var lastMouseMove = 0.0
        var lastFrame = 0.0
        var lastPositions: [CGDirectDisplayID: CGPoint] = [:]
        var history: [(time: Double, value: Double)] = []   // recent signals used for prediction
        var lastPredictiveJump = 0.0
        var predictCandidate: Int? = nil
        var predictStreak = 0
    }
    private var t = TrackingState()

    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3   // continuous yaw/pitch/roll
        return r
    }()

    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3    // pupil landmarks
        return r
    }()

    // MARK: - Lifecycle

    override init() {
        super.init()
        t.rememberPosition = rememberPosition
        t.params = speed.params
        t.moveCursor = moveCursor
        t.frost = frostEnabled
        reloadDisplays()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Turn the camera off while the Mac sleeps or is locked (privacy + battery)
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
            // Calibration starts automatically on first launch
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
        frostOverlay.hideAll()
        videoQueue.async { self.t.gaze = nil; self.t.candidate = nil }
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

    @objc private func pause() {
        runSession(false)
        frostOverlay.hideAll()
        videoQueue.async { self.t.gaze = nil; self.t.candidate = nil }
    }
    @objc private func resume() { if isEnabled { runSession(true) } }
    @objc private func screensChanged() { reloadDisplays() }

    // MARK: - Displays

    private func reloadDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        displays = ids.prefix(Int(count)).map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0)) }
        let saved = UserDefaults.standard.dictionary(forKey: Keys.centers) as? [String: Double] ?? [:]
        centers = displays.map { saved[String($0.id)] }
        frostOverlay.rebuild(displayIDs: displays.map { $0.id })

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
            self.t.gaze = nil
        }
    }

    private func updateStatus() {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .denied || auth == .restricted {
            statusText = "No camera access → System Settings › Privacy › Camera"
        } else if auth == .authorized && !cameraReady {
            statusText = "No camera found"
        } else if !isEnabled {
            statusText = "Paused"
        } else if isCalibrating {
            statusText = "Calibrating…"
        } else if displays.count < 2 {
            statusText = "Waiting for a second monitor"
        } else if centers.contains(where: { $0 == nil }) {
            statusText = "Calibration needed"
        } else {
            statusText = "Running on \(displays.count) monitors"
        }
    }

    // MARK: - Calibration

    func startCalibration() {
        guard !isCalibrating else { return }
        reloadDisplays()
        guard displays.count >= 2 else { statusText = "At least 2 monitors are needed"; return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { updateStatus(); return }

        isCalibrating = true
        frostOverlay.hideAll()
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
                    overlay.setText("Look at the red dot\n\(n)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }

                overlay.setText("Keep looking…")
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
                self.statusText = "Face not detected. Check the lighting and calibrate again"
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s[s.count / 2]
    }

    // MARK: - Cursor

    private func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)   // keep the cursor from freezing after a warp
    }

    // MARK: - Gaze signal (videoQueue)

    /// Head turn (degrees) + pupil offset. Returns nil when no face is found.
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

    /// Where the pupil sits inside the eye: -0.5 (one edge) … +0.5 (other edge)
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

        // Is the user moving the mouse right now?
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

        // Closest calibrated screen + hysteresis (prevents flicker)
        let dists = t.centers.map { abs(avg - $0) }
        guard var target = dists.indices.min(by: { dists[$0] < dists[$1] }) else { return }
        let reference = t.gaze ?? current      // last decision (or the screen the cursor is on)
        if let reference, target != reference, dists[reference] - dists[target] < t.hysteresis {
            target = reference
        }

        // Prediction: the head is turning quickly and clearly toward another screen
        if t.params.predict, let reference,
           now - t.lastPredictiveJump >= predictCooldown {
            if let predicted = predictedTarget(current: reference, signal: avg, now: now) {
                if predicted == t.predictCandidate {
                    t.predictStreak += 1
                } else {
                    t.predictCandidate = predicted
                    t.predictStreak = 1
                }
                // Trust several frames in a row, not a single noisy spike
                if t.predictStreak >= predictFrames {
                    setGaze(predicted)
                    if t.moveCursor, predicted != current, now - t.lastMouseMove >= t.params.idle {
                        jump(to: predicted)
                    }
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

        // Stability: the same decision must hold for params.stable seconds
        if target != t.candidate {
            t.candidate = target
            t.candidateSince = now
            return
        }
        guard now - t.candidateSince >= t.params.stable else { return }

        // 1) Gaze decision changed → update the frosted glass
        if t.gaze != target { setGaze(target) }

        // 2) Move the cursor (if enabled and the user isn't using the mouse)
        if t.moveCursor, target != current, now - t.lastMouseMove >= t.params.idle {
            jump(to: target)
        }
    }

    /// Stores the new gaze decision and updates the frosted glass (videoQueue)
    private func setGaze(_ index: Int) {
        t.gaze = index
        guard t.frost else { return }
        let id = t.displays[index].id
        DispatchQueue.main.async { self.frostOverlay.focus(on: id) }
    }

    /// Moves the cursor to the given screen (videoQueue)
    private func jump(to index: Int) {
        let d = t.displays[index]
        let point = (t.rememberPosition ? t.lastPositions[d.id] : nil)
            ?? CGPoint(x: d.bounds.midX, y: d.bounds.midY)
        warp(to: point)
        t.lastMouse = point
    }

    /// Detects which screen the head is quickly turning toward. Returns nil when unsure.
    private func predictedTarget(current: Int, signal: Double, now: Double) -> Int? {
        // Velocity = slope of the best-fit line through the last 0.15 s of samples.
        // Much more stable than the difference between two points: a single noisy frame,
        // like a quick eye movement, can't ruin the result.
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
        let velocity = num / den   // units per second

        let start = t.centers[current]
        for j in t.centers.indices where j != current {
            let span = t.centers[j] - start
            guard abs(span) > 1 else { continue }

            let progress = (signal - start) / span                // 0 = current screen, 1 = target
            let towardSpeed = span > 0 ? velocity : -velocity      // speed toward the target
            let minSpeed = max(30.0, abs(span) * predictSpeedFactor)

            if progress >= predictMinProgress, progress < 1.5, towardSpeed >= minSpeed {
                return j
            }
        }
        return nil
    }
}

// MARK: - Camera frames

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
