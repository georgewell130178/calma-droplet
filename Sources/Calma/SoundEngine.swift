//
//  SoundEngine.swift
//  Calma
//
//  Ambient sound, synthesised rather than played back: no audio files in the
//  bundle, no audible loop point, and the sound can follow the user's breath
//  sample by sample.
//

import AVFoundation
import Combine
import QuartzCore

/// The sounds Calma can make.
enum AmbientSound: Int, CaseIterable, Identifiable, Sendable {
    case waves
    case rain
    case fire
    case brown

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .waves: "Waves"
        case .rain: "Rain"
        case .fire: "Fire"
        case .brown: "Brown noise"
        }
    }

    /// A word that fits a notch wing.
    var shortTitle: String { self == .brown ? "Noise" : title }

    var icon: String {
        switch self {
        case .waves: "water.waves"
        case .rain: "cloud.rain.fill"
        case .fire: "flame.fill"
        case .brown: "waveform"
        }
    }
}

// MARK: - Parameters

/// What the main actor tells the render thread.
///
/// Backed by raw memory rather than stored properties: the render thread reads
/// these once per buffer while the main actor writes them, and an aligned
/// 64-bit load or store is atomic on both architectures a droplet ships for.
/// A stale read only lags by one buffer, about ten milliseconds, and neither
/// Swift's exclusivity checks nor the allocator ever run on the render path.
final class SynthParameters: @unchecked Sendable {
    private enum Slot: Int, CaseIterable {
        case sound, volume, fade, followsBreath, sessionStart, inhale, holdIn, exhale, holdOut
    }

    private let storage: UnsafeMutablePointer<Double>

    init() {
        storage = .allocate(capacity: Slot.allCases.count)
        storage.initialize(repeating: 0, count: Slot.allCases.count)
        self[.volume] = 0.5
        self[.followsBreath] = 1
        self[.sessionStart] = -1
    }

    deinit { storage.deallocate() }

    private subscript(slot: Slot) -> Double {
        get { storage[slot.rawValue] }
        set { storage[slot.rawValue] = newValue }
    }

    var sound: AmbientSound {
        get { AmbientSound(rawValue: Int(self[.sound])) ?? .waves }
        set { self[.sound] = Double(newValue.rawValue) }
    }

    var volume: Double {
        get { self[.volume] }
        set { self[.volume] = min(max(newValue, 0), 1) }
    }

    /// 1 while playing, 0 while fading out. The synth smooths between them.
    var fade: Double {
        get { self[.fade] }
        set { self[.fade] = newValue }
    }

    var followsBreath: Bool {
        get { self[.followsBreath] > 0.5 }
        set { self[.followsBreath] = newValue ? 1 : 0 }
    }

    /// Starts following a session that began at `mediaTime` on the
    /// `CACurrentMediaTime()` clock, the one the render thread can read.
    func beginBreath(_ timing: BreathTiming, mediaTime: Double) {
        self[.inhale] = timing.inhale
        self[.holdIn] = timing.holdIn
        self[.exhale] = timing.exhale
        self[.holdOut] = timing.holdOut
        // Written last, so the render thread never sees a start without its timing.
        self[.sessionStart] = mediaTime
    }

    func endBreath() {
        self[.sessionStart] = -1
    }

    /// How full the lungs are right now, or `nil` when there is nothing to follow.
    func breathLevel(at mediaTime: Double) -> Double? {
        let start = self[.sessionStart]
        guard start >= 0, followsBreath else { return nil }
        let timing = BreathTiming(
            inhale: self[.inhale],
            holdIn: self[.holdIn],
            exhale: self[.exhale],
            holdOut: self[.holdOut]
        )
        return timing.moment(at: mediaTime - start).level
    }
}

// MARK: - Synth

/// The synthesiser. Once the engine runs, only the render thread touches it.
final class NoiseSynth: @unchecked Sendable {
    private let parameters: SynthParameters
    private let sampleRate: Double
    private let gainSmoothing: Float
    private let swellSmoothing: Float

    private var seed: UInt32 = 0x9E37_79B9
    private var pink0: Float = 0
    private var pink1: Float = 0
    private var pink2: Float = 0
    private var brown: Float = 0
    private var lowpass: Float = 0
    private var dropEnvelope: Float = 0
    private var crackleEnvelope: Float = 0
    private var popEnvelope: Float = 0
    private var clock: Double = 0
    private var gain: Float = 0
    private var swell: Float = 0.5

    init(parameters: SynthParameters, sampleRate: Double) {
        self.parameters = parameters
        self.sampleRate = sampleRate
        // One-pole smoothing, about 80 ms for volume and fades and 250 ms for
        // the swell, so no change ever clicks or zips.
        gainSmoothing = Float(1 - exp(-1 / (0.08 * sampleRate)))
        swellSmoothing = Float(1 - exp(-1 / (0.25 * sampleRate)))
    }

    func render(frameCount: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }

        let sound = parameters.sound
        let targetGain = Float(parameters.volume * parameters.fade)
        let breath = parameters.breathLevel(at: CACurrentMediaTime()).map { Float($0) }
        let step = 1 / sampleRate

        for frame in 0..<frameCount {
            let white = nextNoise()

            // Paul Kellet's economy pink filter, and a leaky integrator for brown.
            pink0 = 0.99765 * pink0 + white * 0.0990460
            pink1 = 0.96300 * pink1 + white * 0.2965164
            pink2 = 0.57000 * pink2 + white * 1.0526913
            let pink = (pink0 + pink1 + pink2 + white * 0.1848) * 0.12
            brown = (brown + 0.02 * white) / 1.02
            lowpass += 0.12 * (white - lowpass)
            let hiss = white - lowpass

            // The waves roll on their own nine-second swell, until a session
            // hands the swell to the breath.
            let swellTarget: Float = breath ?? (sound == .waves ? Self.waveSwell(clock) : 1)
            swell += swellSmoothing * (swellTarget - swell)

            var sample: Float
            switch sound {
            case .waves:
                let body = brown * 3.4 * (0.2 + 0.8 * swell)
                let foam = hiss * 0.16 * swell * swell * swell
                sample = body + foam
            case .rain:
                if nextUnit() < 0.0008 { dropEnvelope = 0.3 + 0.7 * nextUnit() }
                dropEnvelope *= 0.996
                sample = pink * 0.6 + hiss * (0.05 + 0.3 * dropEnvelope)
            case .fire:
                if nextUnit() < 0.0003 { crackleEnvelope = 0.4 + 0.6 * nextUnit() }
                if nextUnit() < 0.00004 { popEnvelope = 1 }
                crackleEnvelope *= 0.982
                popEnvelope *= 0.9993
                sample = brown * 2.2 + pink * 0.12 + hiss * crackleEnvelope * 0.9 + brown * popEnvelope * 3
            case .brown:
                sample = brown * 3.5
            }

            // The waves breathe through the swell itself; everything else
            // breathes through its volume.
            if breath != nil, sound != .waves {
                sample *= 0.4 + 0.6 * swell
            }

            gain += gainSmoothing * (targetGain - gain)
            first[frame] = tanhf(sample * gain * 1.2)
            clock += step
        }

        // Mono source: every other channel gets the same samples.
        for index in 1..<max(buffers.count, 1) {
            guard let channel = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            channel.update(from: first, count: frameCount)
        }
    }

    /// xorshift32: fast, allocation-free, good enough for noise.
    private func nextNoise() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(Int32(bitPattern: seed)) / Float(Int32.max)
    }

    private func nextUnit() -> Float {
        (nextNoise() + 1) / 2
    }

    private static func waveSwell(_ clock: Double) -> Float {
        let phase = (clock / 9).truncatingRemainder(dividingBy: 1)
        let rise = (1 - cos(2 * Double.pi * phase)) / 2
        return Float(pow(rise, 1.5))
    }
}

// MARK: - Engine

enum SoundEngineError: Error {
    case noOutputFormat
}

/// Owns the audio engine. Built on first play, paused once a fade-out
/// finishes, torn down on deactivate.
@MainActor
final class SoundEngine {
    let parameters = SynthParameters()

    private var engine: AVAudioEngine?
    private var pauseTask: Task<Void, Never>?
    private var configurationChange: AnyCancellable?

    func play() throws {
        pauseTask?.cancel()
        pauseTask = nil
        let engine = try self.engine ?? makeEngine()
        parameters.fade = 1
        if !engine.isRunning {
            try engine.start()
        }
    }

    /// Fades out, then pauses the engine so a silent droplet costs nothing.
    func fadeOut() {
        parameters.fade = 0
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.parameters.fade == 0 else { return }
            self.engine?.pause()
        }
    }

    func tearDown() {
        pauseTask?.cancel()
        pauseTask = nil
        configurationChange = nil
        parameters.fade = 0
        parameters.endBreath()
        engine?.stop()
        engine = nil
    }

    private func makeEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = outputRate > 0 ? outputRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw SoundEngineError.noOutputFormat
        }

        let synth = NoiseSynth(parameters: parameters, sampleRate: sampleRate)
        let source = Self.makeSource(format: format, synth: synth)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()

        // A new output device (AirPods connecting, say) stops the engine;
        // pick back up if the user was listening.
        configurationChange = NotificationCenter.default
            .publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resumeAfterConfigurationChange() }

        self.engine = engine
        return engine
    }

    private func resumeAfterConfigurationChange() {
        guard let engine, parameters.fade > 0, !engine.isRunning else { return }
        try? engine.start()
    }

    /// Nonisolated on purpose. A render block formed inside a main-actor
    /// method inherits the main actor, and Swift 6 would assert that on the
    /// audio thread and take the whole host down with it.
    private nonisolated static func makeSource(format: AVAudioFormat, synth: NoiseSynth) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            synth.render(frameCount: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
    }
}
