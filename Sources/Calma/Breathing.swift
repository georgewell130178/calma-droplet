//
//  Breathing.swift
//  Calma
//
//  The breathing model: patterns, phases, and the one pure function that says
//  where in a breath a given moment falls. The orb, the live activity and the
//  audio render thread all ask it the same question, so none of them keeps a
//  clock of its own and they can never drift apart.
//

import Foundation

/// One part of a breath.
enum BreathPhase: String, Sendable {
    case inhale
    case holdIn
    case exhale
    case holdOut

    /// Sentence case, short enough for a notch wing.
    var title: String {
        switch self {
        case .inhale: "Inhale"
        case .holdIn, .holdOut: "Hold"
        case .exhale: "Exhale"
        }
    }
}

/// Where a moment falls inside one breath.
struct BreathMoment: Sendable, Equatable {
    let phase: BreathPhase
    /// How full the lungs are, 0 empty to 1 full, eased so motion starts and
    /// stops gently instead of moving at a constant speed.
    let level: Double
    /// Seconds left in the current phase.
    let remaining: Double

    /// The count a person says out loud: 4, 3, 2, 1.
    var countdown: Int { max(Int(remaining.rounded(.up)), 1) }
}

/// The four durations of a breath, in seconds.
///
/// Doubles only, no strings: the audio render thread builds one of these on
/// its own stack every buffer, and a value that retained anything would touch
/// the allocator on a real-time thread.
struct BreathTiming: Hashable, Sendable {
    var inhale: Double
    var holdIn: Double
    var exhale: Double
    var holdOut: Double

    var cycle: Double { inhale + holdIn + exhale + holdOut }

    func moment(at elapsed: Double) -> BreathMoment {
        guard cycle > 0 else { return BreathMoment(phase: .inhale, level: 0, remaining: 0) }
        var t = elapsed.truncatingRemainder(dividingBy: cycle)
        if t < 0 { t += cycle }

        if t < inhale {
            return BreathMoment(phase: .inhale, level: Self.ease(t / inhale), remaining: inhale - t)
        }
        t -= inhale
        if t < holdIn {
            return BreathMoment(phase: .holdIn, level: 1, remaining: holdIn - t)
        }
        t -= holdIn
        if t < exhale {
            return BreathMoment(phase: .exhale, level: 1 - Self.ease(t / exhale), remaining: exhale - t)
        }
        t -= exhale
        return BreathMoment(phase: .holdOut, level: 0, remaining: holdOut - t)
    }

    /// Sine ease in and out.
    private static func ease(_ progress: Double) -> Double {
        (1 - cos(Double.pi * min(max(progress, 0), 1))) / 2
    }
}

/// A named breathing pattern the user picks in settings.
struct BreathPattern: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// The counts, the way people write them: "4-7-8".
    let counts: String
    let icon: String
    let timing: BreathTiming

    static let balance = BreathPattern(
        id: "balance", title: "Balance", counts: "5-5", icon: "arrow.up.arrow.down",
        timing: BreathTiming(inhale: 5, holdIn: 0, exhale: 5, holdOut: 0)
    )
    static let box = BreathPattern(
        id: "box", title: "Box", counts: "4-4-4-4", icon: "square",
        timing: BreathTiming(inhale: 4, holdIn: 4, exhale: 4, holdOut: 4)
    )
    static let relax = BreathPattern(
        id: "relax", title: "Relax", counts: "4-7-8", icon: "moon",
        timing: BreathTiming(inhale: 4, holdIn: 7, exhale: 8, holdOut: 0)
    )

    static let all: [BreathPattern] = [.balance, .box, .relax]

    static func named(_ id: String) -> BreathPattern {
        all.first { $0.id == id } ?? .balance
    }
}

/// One breathing session in progress.
struct BreathSession: Sendable, Equatable {
    let pattern: BreathPattern
    let start: Date
    /// Rounded up to whole breaths, so a session always finishes a breath
    /// rather than cutting one off halfway.
    let duration: TimeInterval

    init(pattern: BreathPattern, minutes: Int, start: Date = Date()) {
        self.pattern = pattern
        self.start = start
        let cycle = pattern.timing.cycle
        let breaths = (Double(minutes) * 60 / cycle).rounded(.up)
        self.duration = max(breaths, 1) * cycle
    }

    func elapsed(at date: Date) -> TimeInterval { date.timeIntervalSince(start) }

    func moment(at date: Date) -> BreathMoment { pattern.timing.moment(at: elapsed(at: date)) }

    func remaining(at date: Date) -> TimeInterval { max(duration - elapsed(at: date), 0) }
}
