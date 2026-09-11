//
//  CalmaDroplet.swift
//  Calma
//
//  Ambient sound and guided breathing. The droplet owns every piece of state;
//  the views in CalmaViews.swift only read it and call back.
//

import Combine
import DroppyKit
import QuartzCore
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(CalmaPrincipal)
public final class CalmaPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { CalmaDroplet() }
}

/// Preference keys, in one place so the settings pane and the droplet agree.
enum CalmaKey {
    static let sound = "sound"
    static let volume = "volume"
    static let pattern = "pattern"
    static let minutes = "minutes"
    static let followsBreath = "followsBreath"
    static let soundWithSession = "soundWithSession"
    static let tickOnPhase = "tickOnPhase"
    static let pinsDuringSession = "pinsDuringSession"
    static let streak = "streak"
    static let lastSessionDay = "lastSessionDay"
    static let sessionsCompleted = "sessionsCompleted"
}

/// Ambient sound, and a breathing guide the sound can follow.
@MainActor
public final class CalmaDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "calma"

    static let widgetID: ShelfWidgetID = "calma"
    static let sessionLengths = [1, 3, 5, 10]

    private var host: DropletHost?
    private let engine = SoundEngine()
    private var preferenceChanges: AnyCancellable?
    private var ticker: AnyCancellable?
    let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    static let panelID: ExpandedSurfaceID = "calma-panel"
    /// The panel on screen, if Calma put one there. A presentation, not a
    /// surface id: a late dismissal must not clear a panel reopened since.
    private var panelPresentation: ExpandedSurfacePresentation?

    @Published private(set) var isPlaying = false
    @Published private(set) var session: BreathSession?
    /// The phase and count the text shows. Updated only when they change; the
    /// orb reads the session directly, every frame, through its timeline.
    @Published private(set) var phase: BreathPhase = .inhale
    @Published private(set) var countdown = 0
    @Published private(set) var secondsLeft = 0

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        applyPreferencesToEngine()

        // Fires for the settings pane's writes too, so this is the one path
        // that keeps the views and the synth in step with the preferences.
        preferenceChanges = host.preferences.didChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.applyPreferencesToEngine()
                self.publishActivity()
            }

        if host.environment.isHarness {
            showHarnessDemo()
        }
        publishActivity()
        host.log.info("Calma activated")
    }

    public func deactivate() {
        // Everything activate() started stops here. Swift cannot unload code,
        // so a timer or an audio engine left running would run until Droppy
        // relaunches.
        ticker?.cancel()
        ticker = nil
        preferenceChanges?.cancel()
        preferenceChanges = nil
        engine.tearDown()
        isPlaying = false
        session = nil
        panelPresentation = nil
        activitySubject.send(nil)
        host = nil
    }

    // MARK: Sound

    func togglePlayback() {
        isPlaying ? stopSound() : startSound()
    }

    func startSound() {
        do {
            try engine.play()
            isPlaying = true
        } catch {
            host?.log.error("Could not start audio: \(error.localizedDescription)")
        }
        publishActivity()
    }

    func stopSound() {
        engine.fadeOut()
        isPlaying = false
        publishActivity()
    }

    /// Picking a sound plays it: nobody taps rain to look at it.
    func select(_ sound: AmbientSound) {
        engine.parameters.sound = sound
        setPreference(sound.rawValue, CalmaKey.sound)
        if !isPlaying { startSound() }
    }

    var volumeBinding: Binding<Double> {
        Binding(
            get: { self.volume },
            set: {
                self.engine.parameters.volume = $0
                self.setPreference($0, CalmaKey.volume)
            }
        )
    }

    // MARK: Breathing

    func toggleBreathing() {
        if session == nil {
            startBreathing()
        } else {
            finishBreathing(completed: false)
        }
    }

    func startBreathing(at start: Date = Date(), withSound: Bool? = nil) {
        let newSession = BreathSession(pattern: pattern, minutes: minutes, start: start)
        session = newSession
        let alreadyElapsed = newSession.elapsed(at: Date())
        engine.parameters.beginBreath(newSession.pattern.timing, mediaTime: CACurrentMediaTime() - alreadyElapsed)

        if withSound ?? soundWithSession, !isPlaying {
            startSound()
        }

        // Four times a second is plenty for a count; the orb animates on its
        // own timeline and the audio follows the breath on the render thread.
        ticker = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.tick(date) }
        tick(Date())
    }

    func finishBreathing(completed: Bool) {
        ticker?.cancel()
        ticker = nil
        let finished = session
        session = nil
        phase = .inhale
        countdown = 0
        secondsLeft = 0
        engine.parameters.endBreath()
        if completed, let finished {
            recordCompletion(of: finished)
        }
        publishActivity()
    }

    private func tick(_ date: Date) {
        guard let session else { return }
        guard session.remaining(at: date) > 0 else {
            finishBreathing(completed: true)
            return
        }

        let moment = session.moment(at: date)
        var changed = false
        if moment.phase != phase {
            phase = moment.phase
            changed = true
            if tickOnPhase { host?.feedback.play(.tick) }
        }
        if moment.countdown != countdown {
            countdown = moment.countdown
            changed = true
        }
        let left = Int(session.remaining(at: date).rounded(.up))
        if left != secondsLeft {
            secondsLeft = left
        }
        if changed {
            publishActivity()
        }
    }

    private func recordCompletion(of finished: BreathSession) {
        let today = Self.dayKey(Date())
        let yesterday = Self.dayKey(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        let lastDay = preference(CalmaKey.lastSessionDay, "")
        var streak = preference(CalmaKey.streak, 0)

        switch lastDay {
        case today: break
        case yesterday: streak += 1
        default: streak = 1
        }
        streak = max(streak, 1)

        setPreference(streak, CalmaKey.streak)
        setPreference(today, CalmaKey.lastSessionDay)
        setPreference(sessionsCompleted + 1, CalmaKey.sessionsCompleted)

        let minutes = max(Int((finished.duration / 60).rounded()), 1)
        host?.feedback.play(.success)
        presentCompletionHUD(minutes: minutes, streak: streak)
    }

    // MARK: HUD

    /// The one HUD Calma shows: a session finished. It reports a moment, so it
    /// carries a duration and takes itself down.
    private func presentCompletionHUD(minutes: Int, streak: Int) {
        guard let host else { return }
        let streakText = streak == 1 ? "1 day streak" : "\(streak) day streak"

        let request = DropletHUDRequest(
            id: "calma.complete",
            duration: 4,
            priority: .normal,
            accessibilityLabel: "Breathing session complete, \(minutes) minutes, \(streakText)",
            isExpanded: true,
            expandedContentHeight: 44
        ) {
            // Glyph far left, value far right: on a notch the middle of the
            // strip is the camera housing.
            HStack(spacing: 0) {
                Image(systemName: "wind")
                    .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                Spacer(minLength: 0)
                Text(verbatim: "\(minutes) min")
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        } expanded: {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text(verbatim: "Session complete")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.sm) {
                    Text(verbatim: "\(minutes) min")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Text(verbatim: streakText)
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // A refusal is normal: Droppy's own HUDs may own the notch. The
        // moment has passed either way, so nothing retries.
        if !host.hud.present(request) {
            host.log.debug("Completion HUD not shown")
        }
    }

    // MARK: Live activity

    /// Publishes the activity while there is something to show, and `nil`
    /// the moment there is not, so Calma never sits on the seat idle.
    private func publishActivity() {
        guard host != nil, isPlaying || session != nil else {
            activitySubject.send(nil)
            return
        }
        let title = session != nil
            ? "Calma, \(phase.title.lowercased()), \(countdown)"
            : "Calma, playing \(sound.title.lowercased())"
        activitySubject.send(
            LiveActivityState(
                priority: 100,
                accessibilityTitle: title,
                isInteractive: true,
                joinsPersistentActivitySet: session != nil && pinsDuringSession,
                compactPresentation: nil,
                expandedWidgetID: Self.widgetID.rawValue
            )
        )
    }

    // MARK: Panel

    /// Opens Calma's own panel in the notch: the full card, as a takeover.
    /// The shelf widget is the everyday way in; the panel is the way in from
    /// the menu bar, and works where the widget has not been placed.
    func openPanel() {
        guard let host else { return }
        let request = ExpandedSurfacePresentationRequest(surfaceID: Self.panelID, opensShelf: true)
        if let presentation = host.notchSurface.presentExpandedSurface(request) {
            panelPresentation = presentation
        } else {
            host.log.debug("Calma panel not shown")
        }
    }

    func closePanel() {
        guard let host, panelPresentation != nil else { return }
        host.notchSurface.dismissExpandedSurface(Self.panelID)
    }

    func panelDidDismiss(_ presentation: ExpandedSurfacePresentation) {
        if panelPresentation?.id == presentation.id {
            panelPresentation = nil
        }
    }

    /// Breathing started from the menu bar opens the panel too: a guide you
    /// cannot see is not much of a guide.
    func toggleBreathingFromMenu() {
        toggleBreathing()
        if session != nil {
            openPanel()
        }
    }

    // MARK: Harness

    /// The harness draws every surface the moment the droplet activates. A
    /// silent session two and a half seconds in, plus the completion HUD, makes
    /// those pictures show Calma at work instead of idle. Never runs in Droppy.
    private func showHarnessDemo() {
        startBreathing(at: Date().addingTimeInterval(-2.5), withSound: false)
        presentCompletionHUD(minutes: 3, streak: 5)
    }

    // MARK: Preferences

    private func applyPreferencesToEngine() {
        engine.parameters.sound = sound
        engine.parameters.volume = volume
        engine.parameters.followsBreath = followsBreath
    }

    private func preference<Value: Codable>(_ key: String, _ fallback: Value) -> Value {
        host?.preferences.value(forKey: key, default: fallback) ?? fallback
    }

    private func setPreference<Value: Codable>(_ value: Value, _ key: String) {
        host?.preferences.setValue(value, forKey: key)
    }

    func binding<Value: Codable>(_ key: String, _ fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.preference(key, fallback) },
            set: { self.setPreference($0, key) }
        )
    }

    func setPattern(_ pattern: BreathPattern) { setPreference(pattern.id, CalmaKey.pattern) }

    func setMinutes(_ minutes: Int) { setPreference(minutes, CalmaKey.minutes) }

    func debug(_ message: String) { host?.log.debug(message) }

    var sound: AmbientSound {
        AmbientSound(rawValue: preference(CalmaKey.sound, AmbientSound.waves.rawValue)) ?? .waves
    }
    var volume: Double { preference(CalmaKey.volume, 0.5) }
    var pattern: BreathPattern { BreathPattern.named(preference(CalmaKey.pattern, BreathPattern.balance.id)) }
    var minutes: Int { preference(CalmaKey.minutes, 3) }
    var followsBreath: Bool { preference(CalmaKey.followsBreath, true) }
    var soundWithSession: Bool { preference(CalmaKey.soundWithSession, true) }
    var tickOnPhase: Bool { preference(CalmaKey.tickOnPhase, false) }
    var pinsDuringSession: Bool { preference(CalmaKey.pinsDuringSession, false) }
    var sessionsCompleted: Int { preference(CalmaKey.sessionsCompleted, 0) }

    /// The streak as it stands today: it survives until the end of the day
    /// after the last session, then lapses to zero.
    var streak: Int {
        let lastDay = preference(CalmaKey.lastSessionDay, "")
        let today = Self.dayKey(Date())
        let yesterday = Self.dayKey(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        return lastDay == today || lastDay == yesterday ? preference(CalmaKey.streak, 0) : 0
    }

    // MARK: View-facing text

    var streakBadge: String? {
        streak > 0 ? "\(streak) day streak" : nil
    }

    var streakDescription: String {
        switch streak {
        case 0: "None yet"
        case 1: "1 day"
        default: "\(streak) days"
        }
    }

    /// The headline the paired widget and the activity card show.
    var statusTitle: String {
        if session != nil { return "\(phase.title) \(countdown)" }
        return sound.title
    }

    var statusDetail: String {
        if session != nil { return "\(pattern.title) \(pattern.counts) · \(Self.clock(secondsLeft)) left" }
        return isPlaying ? "\(Int((volume * 100).rounded()))% volume" : "Paused"
    }

    /// The same, for the narrow places: the paired widget and the island card.
    var shortStatusDetail: String {
        if session != nil { return "\(Self.clock(secondsLeft)) left" }
        return isPlaying ? "\(Int((volume * 100).rounded()))%" : "Paused"
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
