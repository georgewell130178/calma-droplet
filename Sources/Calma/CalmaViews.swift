//
//  CalmaViews.swift
//  Calma
//
//  Every surface Calma draws: the shelf widget in both layouts, the live
//  activity, and the settings pane. The views read the droplet and call back
//  into it; none of them keeps state or a timer of its own.
//

import Combine
import DroppyKit
import SwiftUI

// MARK: - Shelf widget

extension CalmaDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "Calma",
                systemImage: "wind",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(150)
                ),
                searchKeywords: ["breathe", "breathing", "meditation", "ambient", "rain", "waves", "noise", "focus", "sleep"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(CalmaWidget(droplet: self, isCompact: context.isCompact))
    }
}

/// Solo and paired are different compositions: solo has room for every sound
/// and the volume, paired keeps the orb, the state and the one big action.
/// The notch panel reuses the solo composition, with a close button.
private struct CalmaWidget: View {
    @ObservedObject var droplet: CalmaDroplet
    let isCompact: Bool
    var onClose: (() -> Void)?

    var body: some View {
        Group {
            if isCompact {
                paired
            } else {
                solo
            }
        }
        .padding(DroppySpacing.mdl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var solo: some View {
        HStack(spacing: DroppySpacing.lg) {
            OrbDial(droplet: droplet, size: 108, showsReadout: true)

            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                header

                HStack(spacing: DroppySpacing.xsm) {
                    ForEach(AmbientSound.allCases) { sound in
                        Button {
                            droplet.select(sound)
                        } label: {
                            Image(systemName: sound.icon)
                        }
                        .buttonStyle(CalmaCircleStyle(size: 30, isOn: droplet.isPlaying && droplet.sound == sound))
                        .help(sound.title)
                        .accessibilityLabel(sound.title)
                    }
                    Spacer(minLength: 0)
                    PlayButton(droplet: droplet, size: 30)
                }

                VolumeRow(droplet: droplet)
                BreatheButton(droplet: droplet)
            }
        }
    }

    private var paired: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "wind")
                    .font(.system(size: 12, weight: .medium))
                Text(verbatim: "Calma")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                PlayButton(droplet: droplet, size: 22)
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            HStack(spacing: DroppySpacing.md) {
                OrbDial(droplet: droplet, size: 56, showsReadout: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: droplet.statusTitle)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Text(verbatim: droplet.shortStatusDetail)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                .lineLimit(1)
            }

            Spacer(minLength: 0)
            BreatheButton(droplet: droplet)
        }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "wind")
                .font(.system(size: 12, weight: .medium))
            Text(verbatim: "Calma")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if let badge = droplet.streakBadge {
                Text(verbatim: badge)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(CalmaCircleStyle(size: 20, isOn: false))
                .accessibilityLabel("Close Calma")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }
}

/// The orb with its readout. Tapping it starts or ends a session.
private struct OrbDial: View {
    @ObservedObject var droplet: CalmaDroplet
    let size: CGFloat
    let showsReadout: Bool

    var body: some View {
        ZStack {
            LiveOrb(droplet: droplet, size: size)

            if showsReadout, droplet.session != nil {
                VStack(spacing: 0) {
                    Text(verbatim: "\(droplet.countdown)")
                        .font(.system(size: size * 0.2, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(verbatim: droplet.phase.title)
                        .font(.system(size: max(size * 0.095, 9), weight: .medium))
                }
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .animation(DroppyAnimation.state, value: droplet.countdown)
            } else if droplet.session == nil {
                Image(systemName: droplet.isPlaying ? droplet.sound.icon : "wind")
                    .font(.system(size: size * 0.17, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onTapGesture { droplet.toggleBreathing() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(droplet.session == nil ? "Start breathing" : "End session, \(droplet.phase.title)")
        .accessibilityAddTraits(.isButton)
    }
}

private struct PlayButton: View {
    @ObservedObject var droplet: CalmaDroplet
    let size: CGFloat

    var body: some View {
        Button {
            droplet.togglePlayback()
        } label: {
            Image(systemName: droplet.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(CalmaCircleStyle(size: size, isOn: false))
        .accessibilityLabel(droplet.isPlaying ? "Pause \(droplet.sound.title)" : "Play \(droplet.sound.title)")
    }
}

private struct VolumeRow: View {
    @ObservedObject var droplet: CalmaDroplet

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "speaker.fill")
            Slider(value: droplet.volumeBinding, in: 0...1)
                .controlSize(.mini)
                .tint(AdaptiveColors.notchSurfaceSecondaryText)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 10))
        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        .frame(height: 16)
    }
}

private struct BreatheButton: View {
    @ObservedObject var droplet: CalmaDroplet

    var body: some View {
        Button {
            droplet.toggleBreathing()
        } label: {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: droplet.session == nil ? "wind" : "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: label)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(CalmaPillStyle(isProminent: droplet.session == nil))
    }

    private var label: String {
        if droplet.session != nil {
            return "End · \(CalmaDroplet.clock(droplet.secondsLeft)) left"
        }
        let pattern = droplet.pattern
        return "Breathe · \(pattern.title) \(pattern.counts)"
    }
}

// MARK: - Orb

/// Three flat discs in the user's highlight colour that grow and shrink with
/// the breath. No gradient and no outline: depth comes from opacity alone.
struct BreathOrb: View {
    enum Mode: Equatable {
        case idle
        case ambient
        case session(BreathSession)
    }

    let mode: Mode
    let size: CGFloat
    var isPaused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused || mode == .idle)) { timeline in
            let level = Self.level(for: mode, at: timeline.date)
            ZStack {
                Circle()
                    .fill(AdaptiveColors.selectionBlueAuto.opacity(0.16))
                    .scaleEffect(0.62 + 0.38 * level)
                Circle()
                    .fill(AdaptiveColors.selectionBlueAuto.opacity(0.32))
                    .scaleEffect(0.5 + 0.38 * level)
                Circle()
                    .fill(AdaptiveColors.selectionBlueAuto)
                    .scaleEffect(0.34 + 0.3 * level)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func level(for mode: Mode, at date: Date) -> Double {
        switch mode {
        case .idle:
            return 0.35
        case .ambient:
            // A slow drift on the waves' own nine-second swell.
            let phase = date.timeIntervalSinceReferenceDate / 9
            return 0.35 + 0.2 * (1 - cos(2 * Double.pi * phase)) / 2
        case .session(let session):
            return session.moment(at: date).level
        }
    }
}

/// An orb bound to the droplet's current state.
private struct LiveOrb: View {
    @ObservedObject var droplet: CalmaDroplet
    let size: CGFloat
    var isPaused = false

    var body: some View {
        BreathOrb(mode: mode, size: size, isPaused: isPaused)
    }

    private var mode: BreathOrb.Mode {
        if let session = droplet.session { return .session(session) }
        return droplet.isPlaying ? .ambient : .idle
    }
}

// MARK: - Controls

/// A round control on the dark shelf: card fill at rest, the highlight colour
/// when on. Separated by fill, never by an outline.
private struct CalmaCircleStyle: ButtonStyle {
    let size: CGFloat
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        CalmaCircleBody(configuration: configuration, size: size, isOn: isOn)
    }
}

private struct CalmaCircleBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let isOn: Bool

    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(DroppyAnimation.press, value: configuration.isPressed)
            .animation(DroppyAnimation.state, value: isOn)
            .onHover { hovering in
                withAnimation(DroppyAnimation.hover) { isHovering = hovering }
            }
            .contentShape(Circle())
    }

    private var fill: Color {
        if isOn { return AdaptiveColors.selectionBlueAuto }
        return isHovering || configuration.isPressed
            ? AdaptiveColors.notchSurfaceCardHoverFill
            : AdaptiveColors.notchSurfaceCardFill
    }
}

/// A full-width pill for the one primary action on the widget.
private struct CalmaPillStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        CalmaPillBody(configuration: configuration, isProminent: isProminent)
    }
}

private struct CalmaPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isProminent: Bool

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DroppyRadius.full, style: .continuous)
    }

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .padding(.horizontal, DroppySpacing.md)
            .frame(height: 26)
            .background(shape.fill(fill))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DroppyAnimation.hoverQuick, value: configuration.isPressed)
            .animation(DroppyAnimation.state, value: isProminent)
            .onHover { hovering in
                withAnimation(DroppyAnimation.hover) { isHovering = hovering }
            }
            .contentShape(shape)
    }

    private var fill: Color {
        let active = isHovering || configuration.isPressed
        if isProminent {
            return AdaptiveColors.selectionBlueAuto.opacity(active ? 1 : 0.85)
        }
        return active ? AdaptiveColors.notchSurfaceCardHoverFill : AdaptiveColors.notchSurfaceCardFill
    }
}

// MARK: - Live activity

extension CalmaDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func liveActivitySeatDidChange(_ seat: DropletLiveActivitySeat) {
        // Nothing to pause: the orb's timeline is the only per-frame work, and
        // the host stops drawing it when the seat goes.
        debug("live activity seat is now \(seat)")
    }

    /// The orb, and nothing else. No padding of its own: the host already
    /// insets the wing, by a different amount on a notch and on an island.
    public func makeCompactLeading() -> AnyView {
        AnyView(LiveOrb(droplet: self, size: 18))
    }

    public func makeCompactTrailing() -> AnyView {
        AnyView(CompactTrailing(droplet: self))
    }

    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(ExpandedActivity(droplet: self, context: context))
    }

    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView {
        AnyView(LiveOrb(droplet: self, size: min(context.slotSize.width, context.slotSize.height)))
    }
}

private struct CompactTrailing: View {
    @ObservedObject var droplet: CalmaDroplet

    var body: some View {
        Text(verbatim: droplet.session != nil ? "\(droplet.phase.title) \(droplet.countdown)" : droplet.sound.shortTitle)
            .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}

/// The card the compact activity grows into: the orb, what is happening, and
/// the two controls. Fixed at the host's card height; taller would be clipped.
private struct ExpandedActivity: View {
    @ObservedObject var droplet: CalmaDroplet
    let context: LiveActivityContext

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            LiveOrb(droplet: droplet, size: 48, isPaused: context.presentation.isConcealed)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: droplet.statusTitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                // The island card is 208pt against 344 on a notch: the
                // pattern name does not fit beside two controls there.
                Text(verbatim: context.availableWidth < 300 ? droplet.shortStatusDetail : droplet.statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            .monospacedDigit()
            .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                droplet.togglePlayback()
            } label: {
                Image(systemName: droplet.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(DroppyLiveActivityControlStyle(prominence: .accent))
            .accessibilityLabel(droplet.isPlaying ? "Pause" : "Play")

            Button {
                droplet.toggleBreathing()
            } label: {
                Image(systemName: droplet.session == nil ? "wind" : "stop.fill")
            }
            .buttonStyle(DroppyLiveActivityControlStyle(prominence: .quiet))
            .accessibilityLabel(droplet.session == nil ? "Start breathing" : "End session")
        }
        .frame(width: context.availableWidth, height: DroppyLiveActivityMetrics.cardContentHeight)
    }
}

// MARK: - HUD

/// Calma presents one HUD, when a session completes.
extension CalmaDroplet: HUDPresenting {}

// MARK: - Expanded surface

/// Calma's panel in the notch: the solo card as a takeover, summoned from the
/// menu bar. It keeps the shelf open while you breathe, and a click outside or
/// its close button puts it away.
extension CalmaDroplet: ExpandedSurfaceHosting, ExpandedSurfaceProviding {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }

    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: Self.panelID,
                title: "Calma",
                systemImage: "wind",
                suppresses: [.shelfWidgets, .autoCollapse]
            )
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        guard id == Self.panelID else { return AnyView(EmptyView()) }
        return AnyView(CalmaWidget(droplet: self, isCompact: false, onClose: { [weak self] in self?.closePanel() }))
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        CGSize(width: 420, height: 150)
    }

    public func expandedSurfaceDidDismiss(
        _ id: ExpandedSurfaceID,
        presentation: ExpandedSurfacePresentation,
        reason: ExpandedSurfaceDismissalReason
    ) {
        panelDidDismiss(presentation)
    }
}

// MARK: - Menu bar

/// Everything Calma does, from the menu bar: sounds, volume, a session, and
/// the way into the notch panel.
extension CalmaDroplet: MenuBarExtraProviding {
    public func makeMenuBarExtra() -> MenuBarExtraDescriptor? {
        MenuBarExtraDescriptor(title: "Calma", systemImage: "wind") { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(CalmaMenu(droplet: self))
        }
    }
}

private struct CalmaMenu: View {
    @ObservedObject var droplet: CalmaDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Calma")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: DroppySpacing.md)
                Text(verbatim: droplet.statusTitle)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
            }

            HStack(spacing: DroppySpacing.xsm) {
                ForEach(AmbientSound.allCases) { sound in
                    Button {
                        droplet.select(sound)
                    } label: {
                        Image(systemName: sound.icon)
                    }
                    .buttonStyle(MenuChipStyle(isOn: droplet.isPlaying && droplet.sound == sound))
                    .help(sound.title)
                    .accessibilityLabel(sound.title)
                }
                Spacer(minLength: 0)
                Button {
                    droplet.togglePlayback()
                } label: {
                    Image(systemName: droplet.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(MenuChipStyle(isOn: false))
                .accessibilityLabel(droplet.isPlaying ? "Pause" : "Play")
            }

            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "speaker.fill")
                Slider(value: droplet.volumeBinding, in: 0...1)
                    .controlSize(.mini)
                    .accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.system(size: 10))
            .foregroundStyle(AdaptiveColors.secondaryTextAuto)

            Button {
                droplet.toggleBreathingFromMenu()
            } label: {
                Label(
                    droplet.session == nil
                        ? "Breathe · \(droplet.pattern.title) \(droplet.pattern.counts)"
                        : "End · \(CalmaDroplet.clock(droplet.secondsLeft)) left",
                    systemImage: droplet.session == nil ? "wind" : "stop.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))

            Button {
                droplet.openPanel()
            } label: {
                Label("Show in the notch", systemImage: "rectangle.topthird.inset.filled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(DroppySpacing.md)
        .frame(width: 250, alignment: .leading)
        .foregroundStyle(AdaptiveColors.primaryTextAuto)
    }
}

/// A round control for the menu, on the system's own fills rather than the
/// notch's, because a menu follows the user's appearance.
private struct MenuChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isOn ? AdaptiveColors.selectionForegroundAuto : AdaptiveColors.primaryTextAuto)
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(
                    isOn
                        ? AdaptiveColors.selectionBlueAuto
                        : AdaptiveColors.overlayAuto(configuration.isPressed ? 0.16 : 0.08)
                )
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(DroppyAnimation.press, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

// MARK: - Settings pane

extension CalmaDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(CalmaSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Breathing pattern", keywords: ["breathe", "box", "relax", "4-7-8"]),
            SettingsSearchEntry(title: "Session length", keywords: ["minutes", "timer"]),
            SettingsSearchEntry(title: "Sound follows your breath", keywords: ["waves", "sync", "ambient"])
        ]
    }
}

private struct CalmaSettings: View {
    @ObservedObject var droplet: CalmaDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
            DropletSettingsCard {
                settingsUnifiedPickerRow(
                    title: "Breathing pattern",
                    subtitle: "Balance evens out your rhythm. Box steadies focus. Relax slows you down before sleep.",
                    icon: "wind",
                    options: BreathPattern.all,
                    groupPosition: .top,
                    isSelected: { $0.id == droplet.pattern.id },
                    action: { droplet.setPattern($0) }
                ) { pattern, isSelected, isEnabled in
                    settingsUnifiedSegmentLabel(
                        icon: pattern.icon,
                        title: "\(pattern.title) \(pattern.counts)",
                        isSelected: isSelected,
                        isEnabled: isEnabled
                    )
                }
                DropletSettingsDivider()
                settingsUnifiedPickerRow(
                    title: "Session length",
                    subtitle: "Rounded up so every session ends on a whole breath.",
                    icon: "timer",
                    options: CalmaDroplet.sessionLengths,
                    groupPosition: .bottom,
                    isSelected: { $0 == droplet.minutes },
                    action: { droplet.setMinutes($0) }
                ) { minutes, isSelected, isEnabled in
                    settingsUnifiedSegmentLabel(
                        icon: "clock",
                        title: "\(minutes) min",
                        isSelected: isSelected,
                        isEnabled: isEnabled
                    )
                }
            }

            DropletSettingsCard {
                DropletToggleRow(
                    title: "Sound follows your breath",
                    subtitle: "Waves roll in as you inhale and draw back as you exhale. Other sounds swell and soften.",
                    isOn: droplet.binding(CalmaKey.followsBreath, true)
                )
                DropletSettingsDivider()
                DropletToggleRow(
                    title: "Play sound during sessions",
                    subtitle: "Starts your last sound when you begin breathing.",
                    isOn: droplet.binding(CalmaKey.soundWithSession, true)
                )
                DropletSettingsDivider()
                DropletToggleRow(
                    title: "Tick on each phase",
                    subtitle: "Uses Droppy's own feedback sound, so it follows your sound settings.",
                    isOn: droplet.binding(CalmaKey.tickOnPhase, false)
                )
                DropletSettingsDivider()
                DropletToggleRow(
                    title: "Keep in the notch during sessions",
                    subtitle: "Pins the breathing guide beside the notch. Off, it appears when you hover.",
                    isOn: droplet.binding(CalmaKey.pinsDuringSession, false)
                )
            }

            DropletSettingsCard {
                DropletSliderRow(
                    title: "Volume",
                    value: "\(Int((droplet.volume * 100).rounded()))%",
                    binding: droplet.volumeBinding,
                    range: 0...1,
                    step: 0.1
                )
                DropletSettingsDivider()
                DropletControlRow(title: "Current streak", icon: "flame") {
                    DropletValuePill(text: droplet.streakDescription)
                }
                DropletSettingsDivider()
                DropletControlRow(title: "Sessions completed", icon: "checkmark.circle") {
                    DropletValuePill(text: "\(droplet.sessionsCompleted)")
                }
            }
        }
    }
}
