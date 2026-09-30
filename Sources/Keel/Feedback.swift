import Foundation
import AVFoundation
import AppKit

/// Sound is reserved for the two things nothing else announces: engaging and
/// disengaging capture, and errors.
///
/// Everything else already announces itself — VoiceOver reads the window that comes
/// forward, the volume HUD appears, the Space slides across. A tone on every press is
/// one more thing to hear over the top of that, and it tells you nothing you are not
/// already being told. Actions still confirm in the hand, through the motors, which
/// nothing else does.
public final class Feedback {
    public let chime = Chime()

    /// 0 to 1, from the user's setting. Applied to every pulse.
    public var hapticStrength: Double = 0.55
    weak public var reader: DualSenseReader?

    /// The pending "motors off" for the pulse currently running, so a second pulse can
    /// cancel it. Two overlapping pulses used to leave two independent stops in flight:
    /// the shorter one cut the longer one off early, and the longer one's stop then
    /// landed on whatever had started since. One pulse, one stop, and the newest wins.
    private var rumbleStop: DispatchWorkItem?
    /// A backstop for the stop that never arrives — the controller vanishing mid-pulse,
    /// or a stop report going out while the handle is being closed. The motors on this
    /// controller keep running until something writes to it, so something has to keep
    /// writing until they are known to be quiet.
    private var rumbleWatchdog: Timer?

    public init(reader: DualSenseReader) {
        self.reader = reader
    }

    public func start(useControllerAudio: Bool) {
        chime.useControllerAudio = useControllerAudio
        chime.start()
    }

    /// Re-checks whether the controller's audio device is there. Called when the
    /// controller connects or disconnects, which is the only time it changes.
    public func refreshAudioRoute() {
        chime.refreshRoute()
    }

    /// Byte 7 of the output report selects where the controller sends its audio, and the
    /// open-source drivers for this controller disagree about its bits. Seven hand-picked
    /// guesses was the wrong shape of experiment: it is one byte, so the answer is in it
    /// somewhere and the machine can simply try them all.
    ///
    /// The four output-path settings worth trying.
    ///
    /// Byte 7 of the output report packs several fields, and from the open-source work —
    /// not from Sony, and not verified here — the output path is bits 4 and 5. That makes
    /// 0x00, 0x10, 0x20 and 0x30 the only four values that can move it.
    ///
    /// The first version of this swept byte 7 one value at a time from zero. Sixty-four
    /// steps at two and a half seconds each would have taken nearly three minutes to reach
    /// 0x30, and the owner stopped at fourteen — every one of which was a different
    /// microphone setting with the output path left at zero. Four steps, not sixty-four.
    private static let audioPaths: [UInt8] = [0x00, 0x10, 0x20, 0x30]

    private var huntTimer: Timer?
    private var huntIndex = 0
    public var isSweeping: Bool { huntTimer != nil }

    /// Steps through the four output paths, holding each one under a loud continuous tone.
    ///
    /// Continuous is the point. The actuators click when the audio configuration changes,
    /// so every step of any version of this test produces a bump whatever the path is —
    /// that bump is what the last attempt was reading as a result. A tone that holds for
    /// three seconds cannot be confused with a click at the start of it.
    public func startAudioSweep() {
        guard chime.routedToController else {
            speak("Turn on controller audio first, and plug the controller in over USB.")
            return
        }
        stopAudioSweep(announce: false)
        huntIndex = 0
        speak("""
              Looking for the controller's speaker. Four settings, a long tone on each. \
              Say which one you hear it on. Press again to stop.
              """)
        after(5.5) { self.huntStep() }
        huntTimer = Timer.common(6.5, repeats: true) { [weak self] _ in self?.huntStep() }
    }

    public func stopAudioSweep(announce: Bool = true) {
        guard huntTimer != nil else { return }
        huntTimer?.invalidate()
        huntTimer = nil
        let settled = max(huntIndex - 1, 0)
        if announce, settled < Self.audioPaths.count {
            let path = Self.audioPaths[settled]
            onAudioPathChosen?(path)
            speak("Stopped on setting \(settled + 1). Saved.")
            log("SPEAKER HUNT: stopped and saved output path 0x\(String(format: "%02X", path)).")
        }
    }

    public func toggleAudioSweep() {
        isSweeping ? stopAudioSweep() : startAudioSweep()
    }

    /// Called with the chosen path byte so it can be written to the bindings file.
    public var onAudioPathChosen: ((UInt8) -> Void)?

    private func huntStep() {
        guard huntIndex < Self.audioPaths.count else {
            stopAudioSweep(announce: false)
            speak("""
                  That was all four. If none of them made a sound, say so — the next thing \
                  to try is the speaker volume byte, and after that whether the front pair \
                  reach the speaker at all.
                  """)
            log("SPEAKER HUNT: all four output paths tried with no result reported.")
            return
        }
        let path = Self.audioPaths[huntIndex]
        huntIndex += 1
        // Speaker volume at maximum for the test. It is a parameter rather than a constant
        // precisely because it is one of the things that might be wrong.
        reader?.configureAudio(pathFlags: path, speakerVolume: 0xFF)
        log("SPEAKER HUNT: setting \(huntIndex) of 4 — output path byte 0x\(String(format: "%02X", path)), speaker volume 0xFF.")
        speak("Setting \(huntIndex).")
        after(1.6) {
            self.chime.playTestTone(frequency: 440, duration: 3.4, amplitude: 0.9, target: .audible)
        }
    }

    /// Applies the saved output path. Set by the app from the bindings file.
    public var audioPath: UInt8 = 0x30

    public func applyAudioPath() {
        guard chime.routedToController else { return }
        reader?.configureAudio(pathFlags: audioPath, speakerVolume: 0xFF)
    }

    public func setUseControllerAudio(_ use: Bool) {
        chime.useControllerAudio = use
        chime.refreshRoute()
    }

    /// Whether the haptics are currently coming out of the audio path.
    public var hapticsFromAudio: Bool { chime.routedToController }

    /// Plays the audible half and then the haptic half on their own, a second apart, so
    /// the channel map can be confirmed by ear and by hand rather than taken on trust.
    /// Back Left and Back Right are the actuators according to the open-source work on
    /// this controller, not according to Sony.
    public func testControllerOutput() {
        guard chime.routedToController else {
            speak("The controller is not plugged in over USB, so sounds are going to the Mac.")
            return
        }
        chime.logNextPlay = true
        speak("Sound only.")
        after(1.2) {
            self.chime.play([Chime.Tone(Note.d6, start: 0, duration: 0.3, amplitude: 0.5)],
                            voice: .tinkle, haptics: false)
        }
        after(2.6) { self.speak("Haptics only.") }
        after(3.8) {
            self.chime.play([Chime.Tone(Note.d3, start: 0, duration: 0.45, amplitude: 0.9)],
                            voice: .round, silent: true)
        }
        after(5.2) { self.speak("Both together.") }
        after(6.2) { self.captureOn() }
    }

    /// Low and open. Bowl fundamentals sit far below bell notes — these are roughly two
    /// octaves under the old set, which is most of why they read as calm.
    private enum Note {
        static let d3 = 146.83, g3 = 196.00, a3 = 220.00, d4 = 293.66
        /// A semitone above d3, and only ever played with it. Two notes that close
        /// together do not read as a chord — they read as one thing being struck.
        static let ds3 = 155.56
        static let f4 = 349.23, a4 = 440.00
        /// The launcher's own register — a small bell rather than a bowl, two octaves up,
        /// so it never gets confused with the capture tones.
        static let d6 = 1174.66, fs6 = 1479.98, a6 = 1760.00
        static let d5 = 587.33, e5 = 659.25, g5 = 783.99, a5 = 880.00, b5 = 987.77
    }

    // MARK: What the controller feels like

    /// The controller's own display of Muteny's state: triggers, mute LED, lightbar,
    /// player LEDs.
    ///
    /// The triggers are the point. Everything else in this app tells you what mode you
    /// are in by sound or by speech, which means after the fact, and only if you were
    /// listening. The triggers tell your fingers, continuously, without asking: captured,
    /// they push back from a third of the way down; in mouse mode they push back lightly
    /// from the top, so the two feel different at rest; released, they are free — which
    /// is also how a game expects to find them. The lights are for anyone else in the
    /// room. The mute button's LED is the one exception: it is the capture button, so lit
    /// means captured.
    public func showState(captured: Bool, mouseMode: Bool, launcherOpen: Bool, templateIndex: Int) {
        guard let reader = reader, reader.isConnected else { return }

        let triggers: DualSenseDevice.TriggerEffect
        if mouseMode {
            triggers = .resistance(from: 0, strength: 3)
        } else if captured {
            triggers = .resistance(from: 3, strength: 6)
        } else {
            triggers = .off
        }
        reader.setTriggers(left: triggers, right: triggers)

        let colour: (red: UInt8, green: UInt8, blue: UInt8)
        if launcherOpen { colour = (110, 40, 200) }          // violet: choosing
        else if mouseMode { colour = (0, 150, 110) }          // teal: pointer
        else if captured { colour = (255, 110, 0) }           // amber: Muteny has it
        else { colour = (0, 30, 100) }                        // dim blue: handed back

        reader.setLights(muteLED: captured, lightbar: colour,
                         playerLEDs: Self.playerPattern(templateIndex))
    }

    /// The PlayStation's own player patterns, so template one lights the centre LED and
    /// the rest spread outward the way the console does it.
    private static func playerPattern(_ index: Int) -> UInt8 {
        [0x04, 0x0A, 0x15, 0x1B, 0x1F][min(max(index, 0), 4)]
    }

    /// Spoken, and only spoken: the number is the whole message.
    public func announceBattery() {
        guard let reader = reader, reader.isConnected else {
            speak("No controller connected.")
            return
        }
        let battery = reader.battery
        guard battery.known else {
            speak("Controller battery not reported yet.")
            return
        }
        speak(battery.charging
              ? "Controller battery \(battery.percent) percent, charging."
              : "Controller battery \(battery.percent) percent.")
    }

    public func warnLowBattery(_ percent: Int) {
        chime.play([Chime.Tone(Note.a3, start: 0.0, duration: 0.3, amplitude: 0.5),
                    Chime.Tone(Note.a3, start: 0.4, duration: 0.3, amplitude: 0.5)], voice: .round)
        speak("Controller battery \(percent) percent.")
    }

    /// Shake: everything off, controller handed back. Three quick descending pulses so it
    /// is felt as a distinct event rather than mistaken for a capture chime.
    public func escaped() {
        chime.play([
            Chime.Tone(Note.a3, start: 0.00, duration: 0.25, amplitude: 0.5),
            Chime.Tone(Note.d3, start: 0.12, duration: 0.35, amplitude: 0.5)
        ])
        for index in 0..<3 {
            after(Double(index) * 0.1) {
                self.feel(Touch.escaped, motor: 160 - UInt8(index * 40), duration: 0.05)
            }
        }
    }

    // MARK: The two sounds that earn their place

    /// Rising fifth — the controller is now Muteny's.
    public func captureOn() {
        chime.play([
            Chime.Tone(Note.d4, start: 0.00, duration: 0.42, amplitude: 0.75),
            Chime.Tone(Note.a4, start: 0.09, duration: 0.45, amplitude: 0.60)
        ])
        // One rising glide on the audio route says what the motors needed two pulses to
        // say. The pair is kept for the motors, because a single buzz there carries no
        // direction at all.
        if hapticsFromAudio {
            feel(Touch.captureOn, motor: 0, duration: 0)
        } else {
            pulse(strength: 120, duration: 0.07)
            after(0.14) { self.pulse(strength: 210, duration: 0.11) }
        }
    }

    /// The same interval falling, and lower — handed back.
    public func captureOff() {
        chime.play([
            Chime.Tone(Note.a3, start: 0.00, duration: 0.42, amplitude: 0.70),
            Chime.Tone(Note.d3, start: 0.09, duration: 0.45, amplitude: 0.60)
        ])
        if hapticsFromAudio {
            feel(Touch.captureOff, motor: 0, duration: 0)
        } else {
            pulse(strength: 210, duration: 0.10)
            after(0.14) { self.pulse(strength: 110, duration: 0.07) }
        }
    }

    // MARK: Silent confirmations

    /// A binding ran. Felt, not heard — whatever it did will announce itself.
    public func fired(_ label: String) {
        feel(Touch.fired, motor: 190, duration: 0.06)
        after(0.13) { self.feel(Touch.fired, motor: 190, duration: 0.06) }
    }

    /// Captured, but nothing is bound to that control.
    ///
    /// This used to speak the control's name. It does not any more: VoiceOver has no reason
    /// to talk here, and on a controller where most of the face is bound, hearing the name
    /// of every stray press is noise rather than information. What is left is a short, low,
    /// soft note — plainly different from anything an action makes, and low enough that it
    /// reads as "nothing there" rather than as an error, which has its own tone and should
    /// keep it. For silence instead, delete the `play` line; the pulse alone is enough to
    /// confirm the press was seen.
    public func unbound(_ button: DSButton) {
        feel(Touch.unbound, motor: 70, duration: 0.16)
        chime.play([Chime.Tone(Note.g3, start: 0, duration: 0.16, amplitude: 0.30)], voice: .round)
    }

    // MARK: Errors, which do get a sound

    /// Capture was refused — presses are still reaching other apps. This one keeps its
    /// tone: believing you are isolated when you are not is the worst state to be in,
    /// and nothing else on the machine will tell you.
    public func captureFailed() {
        chime.play([
            Chime.Tone(Note.d3, start: 0.00, duration: 0.40, amplitude: 0.8),
            Chime.Tone(Note.d3 * 1.06, start: 0.10, duration: 0.40, amplitude: 0.6)
        ])
        for index in 0..<3 {
            after(Double(index) * 0.13) { self.feel(Touch.refused, motor: 220, duration: 0.05) }
        }
        speak("Capture failed. Presses still reach other apps.")
    }

    /// An action could not complete. Also keeps a tone: nothing happened, so nothing
    /// else is going to speak.
    public func blocked(_ reason: String) {
        chime.play([Chime.Tone(Note.d3, start: 0.0, duration: 0.45, amplitude: 0.7)])
        feel(Touch.blocked, motor: 160, duration: 0.18)
        speak(reason)
    }

    /// Switching to a named template — spoken, because the name is the whole message.
    public func announce(_ text: String) {
        speak(text)
    }

    /// A row picked up to be moved, and the same row let go. Rising to lift, falling to
    /// drop — opposites in meaning are opposites in the hand, so which one happened is
    /// known without being learned. Both are short: they punctuate a gesture that is still
    /// going on, and the spoken position is the information.
    public func pickedUp() {
        chime.play([Chime.Tone(Note.g3, start: 0.0, duration: 0.10, amplitude: 0.30),
                    Chime.Tone(Note.d4, start: 0.06, duration: 0.14, amplitude: 0.34)],
                   voice: .round, cacheKey: "pickedUp")
        feel(Touch.captureOn, motor: 90, duration: 0.03)
    }

    public func droppedItem() {
        chime.play([Chime.Tone(Note.d4, start: 0.0, duration: 0.10, amplitude: 0.32),
                    Chime.Tone(Note.g3, start: 0.06, duration: 0.16, amplitude: 0.30)],
                   voice: .round, cacheKey: "droppedItem")
        feel(Touch.captureOff, motor: 80, duration: 0.03)
    }

    /// Moving between launcher items, and confirming a captured press in the editor.
    /// Short and soft — it fires often, so it has to sit under whatever is being spoken
    /// rather than compete with it.
    public func tick() {
        // Still low enough to sit under the spoken name rather than cut through it — a
        // high tone competes with speech, and the name is the information. But on the
        // round voice rather than the bowl: whole-number partials, so it reads as one
        // clear note instead of the faint clang the bowl's inharmonic modes give at this
        // pitch. G rather than D, which lifts it out of the mud without reaching speech.
        chime.play([Chime.Tone(Note.g3, start: 0.0, duration: 0.16, amplitude: 0.32)],
                   voice: .round, cacheKey: "tick")
        feel(Touch.tick, motor: 70, duration: 0.014)
    }

    /// Moving from one item to the next.
    ///
    /// Each item used to have its own three-note motif, fixed by its name, so that Shadow PC
    /// and GeForce NOW were told apart by sound before the name was spoken — the way an app
    /// icon works for someone who can see it. It was a good idea for a list you step through
    /// occasionally and the wrong one for a list you move through: a tune under every press
    /// is too much, and it competes with the name VoiceOver is reading, which is the part
    /// that matters.
    ///
    /// So: a pock. One short struck note, dry, over in a twentieth of a second — enough to
    /// mark that something moved and not enough to be listened to. High and light where the
    /// edge knock is low and blunt, so "I moved" and "I could not move" are never confused.
    public func pock() {
        chime.play([
            Chime.Tone(Note.a4, start: 0.0, duration: 0.045, amplitude: 0.30),
            Chime.Tone(Note.d5, start: 0.0, duration: 0.028, amplitude: 0.14)
        ], voice: .tinkle, cacheKey: "pock")
        feel(Touch.tick, motor: 70, duration: 0.014)
    }

    public func launcherAmbience(_ on: Bool) {
        on ? chime.startPad() : chime.stopPad()
    }

    /// The launcher opening. Three small bells climbing — the whole thing is over in a
    /// third of a second, because it lands at the same moment the first item is spoken
    /// and must be out of the way before the name starts.
    public func launcherOpened() {
        chime.play([
            Chime.Tone(Note.d6, start: 0.00, duration: 0.16, amplitude: 0.42),
            Chime.Tone(Note.fs6, start: 0.055, duration: 0.16, amplitude: 0.38),
            Chime.Tone(Note.a6, start: 0.110, duration: 0.20, amplitude: 0.34)
        ], voice: .tinkle, cacheKey: "launcherOpened")
        feel(Touch.launcherOpened, motor: 120, duration: 0.05)
    }

    /// The same three falling. Exactly the inverse, because a shape you have heard
    /// climbing is recognised descending without having to be learned twice.
    public func launcherClosed() {
        chime.play([
            Chime.Tone(Note.a6, start: 0.00, duration: 0.16, amplitude: 0.36),
            Chime.Tone(Note.fs6, start: 0.055, duration: 0.16, amplitude: 0.34),
            Chime.Tone(Note.d6, start: 0.110, duration: 0.20, amplitude: 0.30)
        ], voice: .tinkle, cacheKey: "launcherClosed")
        feel(Touch.launcherClosed, motor: 90, duration: 0.05)
    }

    /// The end of the list. You pushed and it did not move.
    ///
    /// The list used to wrap, and wrapping is disorienting without sight in the way it
    /// never is with it: hold a direction for a moment too long and you are somewhere else
    /// entirely with nothing to say so. It has edges now, and this is what an edge sounds
    /// like — two notes a semitone apart, struck together and damped at once, which reads
    /// as a knock rather than as a note. Deliberately nothing like the movement tick, and
    /// deliberately not the rough "no" texture either: you have not done anything wrong,
    /// you have found the end.
    ///
    /// Sound rather than speech, because it happens often and a sentence would be in the
    /// way of the name VoiceOver is reading.
    public func edge() {
        chime.play([
            Chime.Tone(Note.d3, start: 0.0, duration: 0.075, amplitude: 0.34),
            Chime.Tone(Note.ds3, start: 0.0, duration: 0.065, amplitude: 0.26)
        ], voice: .round, cacheKey: "edge")
        feel(Touch.edge, motor: 105, duration: 0.018)
    }

    /// The small events inside the library that have no chime of their own. Each is a
    /// shape rather than a pitch: the pairs that are opposites in meaning are opposites in
    /// the hand and in the ear, which is the same rule the capture tones follow.
    public func libraryEvent(_ event: String) {
        switch event {
        case "category":
            // Two notes, neither rising nor falling far — you moved sideways.
            chime.play([
                Chime.Tone(Note.g5, start: 0.00, duration: 0.13, amplitude: 0.30),
                Chime.Tone(Note.a5, start: 0.065, duration: 0.15, amplitude: 0.28)
            ], voice: .round, cacheKey: "library:category")
            feel(Touch.category, motor: 110, duration: 0.04)
        case "favourited":
            // Up, and bright. Something was added.
            chime.play([
                Chime.Tone(Note.a5, start: 0.00, duration: 0.13, amplitude: 0.34),
                Chime.Tone(Note.d6, start: 0.070, duration: 0.18, amplitude: 0.30)
            ], voice: .tinkle, cacheKey: "library:favourited")
            feel(Touch.favourited, motor: 150, duration: 0.05)
        case "unfavourited":
            // Exactly the inverse, for exactly the inverse meaning.
            chime.play([
                Chime.Tone(Note.d6, start: 0.00, duration: 0.13, amplitude: 0.30),
                Chime.Tone(Note.a5, start: 0.070, duration: 0.18, amplitude: 0.26)
            ], voice: .tinkle, cacheKey: "library:unfavourited")
            feel(Touch.unfavourited, motor: 120, duration: 0.05)
        case "surprise":
            // Three notes that do not go anywhere in particular, which is the point.
            chime.play([
                Chime.Tone(Note.d5, start: 0.00, duration: 0.11, amplitude: 0.30),
                Chime.Tone(Note.b5, start: 0.055, duration: 0.11, amplitude: 0.28),
                Chime.Tone(Note.g5, start: 0.110, duration: 0.16, amplitude: 0.26)
            ], voice: .tinkle, cacheKey: "library:surprise")
            feel(Touch.surprise, motor: 140, duration: 0.05)
        default:
            tick()
        }
    }

    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Plays a representative pulse so the strength setting can be felt while it is being
    /// changed, rather than guessed at and tested later.
    public func testHaptics() {
        feel(Touch.fired, motor: 190, duration: 0.06)
        after(0.13) { self.feel(Touch.fired, motor: 190, duration: 0.06) }
    }

    /// What each event feels like.
    ///
    /// The motors could only ever vary how hard and how long, so every event felt like
    /// every other one at a different volume. Through the audio path there is pitch and,
    /// more usefully, pitch *movement* — and rising against falling is told apart by hand
    /// instantly, without having to be learned. So the pairs that are opposites in meaning
    /// are opposites in the hand too: capture on rises and capture off falls, the launcher
    /// opening rises and closing falls. The things that mean "no" are rough where
    /// everything else is smooth, which is the one texture that reads as wrong.
    ///
    /// These are deliberately the same shapes as the sounds. A chime already carries its
    /// own envelope down to the actuators inside `play`; this is the same idea for the
    /// events that have no chime, or whose chime is doing something else.
    private enum Touch {
        /// Rising and swelling: something opened and is being held open.
        static let captureOn = Chime.Haptic(from: 48, to: 132, strength: 0.95,
                                            duration: 0.30, attack: 0.030, decay: 3.5)
        /// The mirror of it, and a shade quicker — closing is a smaller event than opening.
        static let captureOff = Chime.Haptic(from: 132, to: 48, strength: 0.85,
                                             duration: 0.26, attack: 0.006, decay: 5.5)
        /// A firm, flat knock. An action ran; nothing is being entered or left.
        static let fired = Chime.Haptic(from: 104, strength: 0.80,
                                        duration: 0.09, attack: 0.002, decay: 34)
        /// One item's worth of movement, and as close to nothing as the hardware allows.
        ///
        /// It was three times this long, and at a rate of ten or fifteen a second — which is
        /// what holding a direction does — three times too long stops being a tap and
        /// becomes a buzz. Sixteen milliseconds with a decay steep enough to finish inside
        /// that is a click rather than a pulse. The motors cannot go this short, because a
        /// voice coil has to spin up before it does anything; on that path the
        /// twenty-millisecond floor in `pulse` is already the shortest tap there is.
        static let tick = Chime.Haptic(from: 168, strength: 0.34,
                                       duration: 0.016, attack: 0.0008, decay: 150)
        /// Low, soft and slow. There is nothing on this control; it should feel like
        /// pressing into something that does not answer rather than like a mistake.
        static let unbound = Chime.Haptic(from: 42, strength: 0.42,
                                          duration: 0.20, attack: 0.045, decay: 9)
        /// Rough and insistent. Capture was refused, and believing you are isolated when
        /// you are not is the worst state to be in.
        static let refused = Chime.Haptic(from: 82, strength: 1.0, duration: 0.22,
                                          attack: 0.002, decay: 5, roughness: 0.85)
        /// Rough, but lower and shorter — blocked is a smaller "no" than refused.
        static let blocked = Chime.Haptic(from: 62, strength: 0.75, duration: 0.24,
                                          attack: 0.004, decay: 6, roughness: 0.55)
        /// Falling and heavy: everything dropped at once.
        static let escaped = Chime.Haptic(from: 120, to: 44, strength: 0.95,
                                          duration: 0.34, attack: 0.002, decay: 5)
        static let launcherOpened = Chime.Haptic(from: 58, to: 112, strength: 0.7,
                                                 duration: 0.16, attack: 0.010, decay: 12)
        static let launcherClosed = Chime.Haptic(from: 112, to: 58, strength: 0.6,
                                                 duration: 0.15, attack: 0.004, decay: 14)
        /// Two soft knocks, low. A warning that is not an emergency.
        static let battery = Chime.Haptic(from: 66, strength: 0.7,
                                          duration: 0.13, attack: 0.008, decay: 20)
        /// A wall. Hard attack, no glide, gone at once — the hand's version of a stop.
        /// Firmer than the movement tick and much shorter, so the two are never confused.
        static let edge = Chime.Haptic(from: 60, strength: 0.55,
                                       duration: 0.026, attack: 0.0006, decay: 110)
        /// Sideways: a small swell that neither climbs nor falls far.
        static let category = Chime.Haptic(from: 92, to: 116, strength: 0.6,
                                           duration: 0.08, attack: 0.004, decay: 26)
        /// Up, and held a moment longer than it needs — something was kept.
        static let favourited = Chime.Haptic(from: 76, to: 148, strength: 0.75,
                                             duration: 0.14, attack: 0.004, decay: 16)
        /// The same, backwards.
        static let unfavourited = Chime.Haptic(from: 148, to: 76, strength: 0.6,
                                               duration: 0.13, attack: 0.003, decay: 18)
        /// A flick rather than a knock.
        static let surprise = Chime.Haptic(from: 130, to: 96, strength: 0.65,
                                           duration: 0.10, attack: 0.002, decay: 30)
    }

    /// Plays a shaped haptic on the audio route, or the nearest the motors can manage.
    ///
    /// Over Bluetooth there is no audio device, so the motors do the work and all they can
    /// carry is how hard and how long — `motor` and `duration` are that fallback, and they
    /// are what the whole app used to do.
    private func feel(_ haptic: Chime.Haptic, motor: UInt8, duration: TimeInterval) {
        guard chime.routedToController else {
            pulse(strength: motor, duration: duration)
            return
        }
        var scaled = haptic
        scaled.strength = min(haptic.strength * hapticStrength * 1.7, 1.0)
        guard scaled.strength > 0.01 else { return }
        chime.hapticPulse(scaled)
    }

    private func pulse(strength: UInt8, duration: TimeInterval) {
        // Two ways of making the grips move, and they cannot both be used.
        //
        // Classic rumble asserts valid_flag0 bits 0 and 1, which puts the voice coils into
        // rumble emulation — after which they stop answering the audio channels until the
        // audio configuration is written again. So every pulse sent while the audio route
        // was up was quietly undoing it, which is why the speaker could never be found: the
        // test set the path, and the tone that followed arrived after a spoken number whose
        // pulse had already switched the coils back.
        //
        // So: audio route up, haptics come from the audio path and no rumble report is sent
        // at all. Route down — Bluetooth, or the setting turned off — and the motors do the
        // work as before. Turning off "use the controller's speaker and haptics" in the
        // Status tab is the way back to motor rumble if the audio ones disappoint.
        if chime.routedToController {
            chime.hapticPulse(Chime.Haptic(
                from: 70,
                strength: min(Double(strength) / 255.0 * hapticStrength * 1.6, 1.0),
                duration: max(duration, 0.14),
                decay: 26))
            return
        }
        let scaled = UInt8(min(max(Double(strength) * hapticStrength, 0), 255))
        guard scaled > 0 else { return }
        guard let device = reader?.activeDevice else { return }

        rumbleStop?.cancel()
        rumbleWatchdog?.invalidate()
        device.rumble(scaled)

        // Deliberately not captured: the device that stops the motors is looked up again
        // when the stop runs. Holding the one that started them meant that unplugging
        // mid-pulse sent the stop to a dead handle and the grips carried on.
        let stop = DispatchWorkItem { [weak self] in
            self?.stopRumble()
        }
        rumbleStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0.02), execute: stop)

        // Ordinary stops cancel this. It only ever fires when one was lost.
        rumbleWatchdog = Timer.common(max(duration, 0.02) + 0.6, repeats: false) { [weak self] _ in
            log("Rumble watchdog fired — a stop was missed. Silencing the motors.")
            self?.stopRumble()
        }
    }

    /// Stops the motors on whichever controller is attached right now, and says so if it
    /// could not — a silent failure here is felt in the hand for the next several seconds.
    private func stopRumble() {
        rumbleStop?.cancel()
        rumbleStop = nil
        rumbleWatchdog?.invalidate()
        rumbleWatchdog = nil
        guard let device = reader?.activeDevice else {
            log("Rumble stop had no device to send to — the controller went away mid-pulse.")
            return
        }
        device.rumble(0)
    }

    /// Routed through VoiceOver when it is running, so these use your voice and rate and
    /// queue with what VoiceOver is already saying rather than talking over it.
    private func speak(_ text: String) {
        Announcer.say(text, interrupting: true)
    }
}
