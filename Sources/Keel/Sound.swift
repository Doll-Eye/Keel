import Foundation
import AVFoundation
import CoreAudio

/// Every sound is synthesised at runtime — no audio files to ship or lose.
///
/// Modelled on a singing bowl rather than a struck bell. Three things make the
/// difference: the partials are sparse and widely spaced (roughly 1, 2.7, 5.2 — a bowl
/// has far fewer modes than a bell, which is why it reads as calm rather than bright);
/// the attack is a slow swell over about 80ms instead of a strike; and each partial is
/// paired with a twin a couple of hertz away, so the two drift in and out of phase and
/// produce the slow breathing pulse that makes a bowl sound alive. Decay is long —
/// several seconds on the fundamental — with the upper partials fading much sooner, so
/// the sound settles into a low hum rather than stopping.
public final class Chime {

    public struct Tone {
        public let frequency: Double
        public let start: Double
        public let duration: Double
        public let amplitude: Double

        public init(_ frequency: Double, start: Double = 0, duration: Double = 0.5, amplitude: Double = 1.0) {
            self.frequency = frequency
            self.start = start
            self.duration = duration
            self.amplitude = amplitude
        }
    }

    public typealias Partial = (ratio: Double, amplitude: Double, decay: Double, beat: Double)

    /// Which instrument a sound is played on.
    ///
    /// The bowl is the house voice, and its partials are inharmonic — 1, 2.71, 5.18 —
    /// which is exactly what makes a bowl a bowl. That is right for a sound you hear twice
    /// a session and wrong for one you hear on every move: inharmonic partials are what
    /// the ear reads as "clang", and a clang forty times in a row is tiring.
    ///
    /// So `round` uses whole-number partials — an octave and a twelfth over the
    /// fundamental — which is the same note reinforced rather than a chord of unrelated
    /// ones. `tinkle` is a small struck bell: near-harmonic, very short, bright enough to
    /// be heard over speech without sitting on top of it.
    public enum Voice {
        case bowl, round, tinkle

        public var partials: [Partial] {
            switch self {
            case .bowl:
                return [(1.000, 1.00, 1.0, 1.4),
                        (2.710, 0.26, 2.2, 2.1),
                        (5.180, 0.08, 3.8, 3.0),
                        (8.120, 0.025, 5.5, 4.2)]
            case .round:
                return [(1.000, 1.00, 1.0, 0.7),
                        (2.000, 0.22, 2.0, 1.1),
                        (3.000, 0.06, 3.4, 1.5)]
            case .tinkle:
                return [(1.000, 1.00, 1.0, 0.0),
                        (2.004, 0.45, 1.5, 1.6),
                        (3.010, 0.16, 2.4, 2.2),
                        (4.020, 0.05, 3.6, 2.8)]
            }
        }

        /// How fast it dies away. Higher is shorter.
        public var decayRate: Double {
            switch self {
            case .bowl: return 6.5
            case .round: return 9.5
            case .tinkle: return 13.0
            }
        }

        /// Length of the swell at the front. A bowl is rung; a bell is struck.
        public var attack: Double {
            switch self {
            case .bowl: return 0.025
            case .round: return 0.010
            case .tinkle: return 0.003
            }
        }
    }

    // Fixed for the life of the app, deliberately.
    //
    // Replacing the engine and its nodes on the error path was tried and abandoned: it
    // crashed the app four times in twenty minutes. AVAudioEngine answers a graph change it
    // does not like by raising an Objective-C exception rather than returning an error, and
    // Swift cannot catch that — it aborts the process. Every extra moment where a node
    // might not belong to the engine being asked about it is another chance to hit one.
    // Nothing here is replaced now; the graph is rebuilt in place, which is what ran for an
    // hour without trouble before any of this started.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    /// The launcher's ambience, and **its own engine**.
    ///
    /// An `AVAudioEngine` has one output device, so a single engine cannot put the music on
    /// the Mac and the movement sounds on the controller at the same time — and that split
    /// is the point. The chimes belong on the controller because that is where they are
    /// *felt*: the voice coils carry the same signal, so a sound in the hand and a sound in
    /// the ear are one event. Music through a small speaker in a controller is just a worse
    /// speaker. So the pad has an engine of its own, on the system default output, and it
    /// stays there whatever the main engine is doing.
    ///
    /// The second benefit is that it is no longer part of the route switch at all. The main
    /// graph is torn down and rebuilt every time the controller comes and goes, and that
    /// path has cost this app more crashes than everything else together; the pad is now
    /// one player, one connection, one loop, and none of it moves.
    private let pad = AVAudioPlayerNode()
    private let padEngine = AVAudioEngine()
    private var padObserver: NSObjectProtocol?
    private var padAttached = false
    /// Stereo at 44.1k, the same as the Mac path. The mixer converts to whatever the
    /// hardware is actually running at.
    private let padFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                         channels: 2, interleaved: false)!
    /// The controller path bypasses the main mixer on purpose, but two players still
    /// need summing somewhere; this one is told the four-channel format explicitly so it
    /// passes the haptic pair through untouched.
    private let controllerMixer = AVAudioMixerNode()
    /// Haptics get their own player so they sound with a chime rather than after it: a
    /// player plays its buffers one after another, so anything sharing the chime's node
    /// waits for the chime to finish.
    private let hapticPlayer = AVAudioPlayerNode()
    private var padFade: Timer?
    private var padIsUp = false
    /// The rendered loop, kept between openings. It is eight seconds of eight detuned
    /// voices — a few million sine calls — and rendering that on the main thread every time
    /// the library opened would be felt as a hitch at exactly the wrong moment. The format
    /// it was rendered for is kept with it, because a route change to the controller makes
    /// the engine four-channel and the old buffer no longer fits.
    private var padBuffer: AVAudioPCMBuffer?
    /// Rendered chimes, kept by name.
    ///
    /// Every chime in this app is synthesised from scratch when it is played — a few
    /// hundred thousand sine calls for a three-note earcon, on the main thread, while the
    /// person is holding a direction on the D-pad and expecting the next item. The sounds
    /// that repeat are identical every time they are played, so they are rendered once and
    /// kept: after the first press on an item, its earcon costs a dictionary lookup.
    ///
    /// The signature is the format the cache was built for. Moving the output to the
    /// controller makes the engine four-channel, and a buffer of the wrong shape handed to
    /// `scheduleBuffer` is one of the things AVAudioEngine answers with an exception rather
    /// than an error, so the whole cache is dropped when the format changes.
    private var chimeCache: [String: AVAudioPCMBuffer] = [:]
    private var chimeCacheSignature = ""
    private let chimeCacheLimit = 150
    private var format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var started = false

    /// Whether Muteny is allowed to use the controller's own speaker and haptics when it
    /// is plugged in. Off means the Mac's output, always.
    public var useControllerAudio = true

    /// True while output is going to the controller. Read by Feedback, which stops driving
    /// the rumble motors in that state — the haptics are coming from the audio instead and
    /// the two fight over the same actuators.
    private(set) var routedToController = false

    /// Where the extra pair of channels goes. Over USB the DualSense presents a single
    /// four-channel stream: Front Left and Front Right are audible, Back Left and Back
    /// Right drive the voice-coil actuators in the grips. That mapping comes from the
    /// open-source work on this controller rather than from Sony, so "Test the controller"
    /// in the Status tab plays the audible part and the haptic part separately — if they
    /// come out the wrong way round, these two constants swap.
    private let audibleChannels = (left: 0, right: 1)
    private let hapticChannels = (left: 2, right: 3)

    private var configurationObserver: NSObjectProtocol?
    private var restartAttempts = 0
    /// How many times the controller route has been tried and failed since it last worked.
    private var controllerRouteAttempts = 0
    private var playerStartFailures = 0
    /// True while the graph is being torn down and rebuilt. See `buildGraph`.
    private var rebuilding = false

    private func attachNodes() {
        engine.attach(player)
        engine.attach(reverb)
        engine.attach(hapticPlayer)
        engine.attach(controllerMixer)
        // Switching the output device is itself a configuration change: the engine stops
        // on it, without error, a few milliseconds after start() returns true. Without
        // this observer the graph looks healthy and every sound after it is discarded.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] note in
                self?.handleConfigurationChange(note)
            }
    }

    public func start() {
        guard !started else { return }
        attachNodes()
        // Start on the Mac's output even when the controller is plugged in, and move over a
        // beat later.
        //
        // Building the controller graph inside start() does not work: switching the output
        // device to the four-channel controller before the engine has ever run makes
        // engine.start() fail with kAudioHardwareUnspecifiedError ('what'). The identical
        // switch a second later, through refreshRoute, succeeds every time. That was always
        // the path it took in practice — the setting used to be off at launch, so the route
        // only ever came up after the controller connected — and turning the setting on
        // permanently exposed the launch-time path for the first time.
        //
        // The failure was not survivable either: the fallback to the Mac's output raised an
        // Objective-C exception from deep inside AVAudioEngine, which unwound out of here
        // and took the rest of startup with it, including the HID reader. The app stayed
        // running with no sound, no controller and no log line saying so.
        _ = buildGraph(useController: false)
        AudioDevices.logAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshRoute()
        }
    }

    deinit {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleConfigurationChange(_ notification: Notification) {
        // The notification is delivered through an operation queue, and `removeObserver`
        // does not cancel blocks already sitting on it. So a change belonging to an engine
        // that has since been thrown away can still arrive here, and acting on it would
        // rebuild the current graph for a reason that no longer applies.
        guard (notification.object as AnyObject?) === engine else { return }
        guard started, !rebuilding else { return }

        // Off the callout before touching the graph.
        //
        // This notification is delivered while AVAudioEngine is part-way through its own
        // reconfiguration, and taking the graph apart underneath it from inside the
        // callout raised from `disconnectNodeOutput` and aborted the process — twice.
        // A turn of the run loop later the engine has finished settling and the same work
        // is ordinary.
        //
        // One turn was not always enough. On 25 Sep 2026 a change arrived 30 ms after the
        // route had moved to the controller (AirPods Max also connected), the rebuild ran on
        // the next turn, and `disconnectNodeOutput` raised inside AVAudioEngine and aborted
        // the process two seconds after launch. So the engine gets a third of a second to
        // settle, and the first thing tried is restarting the graph as it stands — no
        // disconnection at all. Only when that does not run is the graph torn down.
        log("Audio engine configuration changed — restarting.")
        started = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.rebuilding, !self.started else { return }
            if self.restartInPlace() { return }
            log("Restarting in place did not work — rebuilding the graph.")
            if self.buildGraph(useController: self.routedToController) { return }
            _ = self.buildGraph(useController: false)
        }
    }

    /// Starts the engine again on the graph it already has. Nothing is disconnected, which is
    /// the step AVAudioEngine has raised on. Declines when the controller route is up but the
    /// controller's audio device has gone, because then the graph really does need rebuilding.
    private func restartInPlace() -> Bool {
        if routedToController, controllerOutput() == nil { return false }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log("Audio engine did not restart in place: \(error.localizedDescription)")
            return false
        }
        guard engine.isRunning else { return false }
        startPlayers()
        started = true
        log("Audio engine restarted in place. Output: \(routedToController ? "controller" : "system").")
        logGraph()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.verifyRunning() }
        return true
    }

    /// `engine.isRunning` is true the instant start() returns and false again a moment
    /// later, so it is checked twice: once immediately, once after the configuration has
    /// had time to settle. Three failed attempts and the controller route is abandoned for
    /// the Mac's output, because being silent everywhere is the worse failure.
    /// Starts the two player nodes.
    ///
    /// Never fatal. A player that will not start is recoverable — `verifyRunning` comes
    /// back for it — whereas treating it as fatal once took the whole route down and left
    /// the app with no sound at all rather than with a quiet player.
    private func startPlayers() {
        guard engine.isRunning else { return }
        startPlayer(player, "chimes")
        // Only on the controller route; on the Mac's output it is attached but not
        // connected, and there is nowhere for a haptic to go.
        if routedToController { startPlayer(hapticPlayer, "haptics") }
    }

    /// Starts one player, having first checked the two things that make starting one fatal.
    ///
    /// `playAudio()` does not always return its error. On a node that is not attached to
    /// the running engine, or that has no output connection, it raises instead — and a
    /// raise from here is not catchable from Swift and aborts the process. It did exactly
    /// that once, in this function, on a graph that had gone inconsistent underneath it.
    /// The `do/catch` is still worth having for the errors it does return; the guard is
    /// what stops the ones it does not.
    private func startPlayer(_ node: AVAudioPlayerNode, _ name: String) {
        guard node.engine === engine else {
            log("Not starting the \(name) player — it belongs to an engine that is gone.")
            return
        }
        guard !engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty else {
            log("Not starting the \(name) player — it is attached but not connected.")
            return
        }
        do {
            try node.playAudio()
        } catch {
            log("The \(name) player did not start: \(error.localizedDescription). Will retry.")
        }
    }

    private func verifyRunning() {
        guard started else { return }
        if engine.isRunning {
            restartAttempts = 0
            // The engine running is not the same as the player running, and a player that
            // is not playing discards every buffer scheduled onto it without complaint.
            if !player.isPlaying {
                startPlayers()
                if player.isPlaying {
                    playerStartFailures = 0
                    log("Audio player restarted after a late start.")
                } else {
                    // Retrying a player that will not start is pointless when the reason is
                    // an inconsistent graph — it was refused for the same reason last time.
                    // Rebuild rather than log the same line forever, because the symptom of
                    // this is an app that makes no sound and says nothing about it.
                    playerStartFailures += 1
                    log("Audio player will not start (\(playerStartFailures)).")
                    if playerStartFailures >= 3 {
                        playerStartFailures = 0
                        log("Rebuilding the audio graph to get the player back.")
                        started = false
                        _ = buildGraph(useController: false)
                    }
                }
            } else {
                playerStartFailures = 0
            }
            return
        }

        restartAttempts += 1
        log("Audio engine stopped on its own (attempt \(restartAttempts)).")
        started = false

        guard restartAttempts <= 3 else {
            log("Giving up on the controller route — using the Mac's output.")
            restartAttempts = 0
            _ = buildGraph(useController: false)
            return
        }
        if !buildGraph(useController: routedToController) {
            _ = buildGraph(useController: false)
        }
    }

    /// The controller's audio device only exists while it is plugged in over USB — over
    /// Bluetooth there is nothing to find — so "is it there" is the whole of the decision
    /// and the fallback needs no separate rule.
    private func controllerOutput() -> (id: AudioDeviceID, channels: Int)? {
        guard useControllerAudio else { return nil }
        for device in AudioDevices.all()
        where device.name.localizedCaseInsensitiveContains("DualSense")
           || device.name.localizedCaseInsensitiveContains("Wireless Controller") {
            let total = AudioDevices.channels(device.id, input: false).reduce(0, +)
            if total >= 4 { return (device.id, total) }
        }
        return nil
    }

    /// Builds the graph for whichever output is in play. Called at launch and whenever the
    /// controller comes or goes.
    private func configureRoute() {
        // The controller path is attempted first and verified, not assumed. If it does not
        // come up, the Mac's output is rebuilt immediately — a feature that fails by making
        // the whole app silent is worse than the feature not existing.
        if buildGraph(useController: true) {
            controllerRouteAttempts = 0
            return
        }
        if routedToController {
            // The engine is rebuilt on the way out of the controller route, but that
            // happens inside buildGraph, where every path off the route converges. Doing it
            // here as well rebuilt it twice for every failure.
            log("Controller audio did not come up — falling back to the Mac's output.")
        }
        _ = buildGraph(useController: false)
        scheduleControllerRouteRetry()
    }

    /// One more go, a second later.
    ///
    /// Moving the engine's output device is itself a configuration change, and the switch
    /// that fails outright can succeed on the next attempt — that is already written down
    /// about the launch path in the README, where the controller route cannot be built
    /// inside `start()` but works a second later through `refreshRoute`. The same is true
    /// when the device being left behind is an awkward one: a Bluetooth headset running at
    /// 24 kHz, for instance, where the first attempt came back with
    /// kAudioHardwareUnspecifiedError ('what').
    ///
    /// Nothing retried before, because `refreshRoute` only runs when the controller comes or
    /// goes — so one failed attempt at the wrong moment meant no controller sound and no
    /// haptics until it was next unplugged. Capped, because a route that will not come up
    /// after three tries is not going to, and rebuilding the graph on a timer forever is the
    /// kind of thing that makes an app crash at four in the morning.
    private func scheduleControllerRouteRetry() {
        guard useControllerAudio, controllerOutput() != nil else {
            controllerRouteAttempts = 0
            return
        }
        guard controllerRouteAttempts < 3 else {
            log("Controller audio: giving up after \(controllerRouteAttempts) attempts. "
                + "Unplug and replug, or toggle the setting, to try again.")
            return
        }
        controllerRouteAttempts += 1
        let attempt = controllerRouteAttempts
        log("Controller audio: retrying the route in a second (attempt \(attempt + 1)).")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, !self.routedToController,
                  self.useControllerAudio, self.controllerOutput() != nil else { return }
            self.configureRoute()
        }
    }

    /// Returns true if the requested route is running. A successful `engine.start()` is
    /// not proof of that: with the controller's four-channel device the engine has been
    /// seen to return from `start()` without throwing and with `isRunning` false, after
    /// which every chime is discarded in silence with nothing logged.
    @discardableResult
    private func buildGraph(useController: Bool) -> Bool {
        // Not re-entrant, and re-entering it is easy: stopping the engine, attaching a node
        // and connecting one can each post an AVAudioEngineConfigurationChange, and the
        // observer calls straight back in here.
        //
        // That was merely wasteful while the nodes lived for the life of the app. It became
        // a crash as soon as a failed route started replacing them — the inner call swapped
        // the engine and every node, the outer call carried on and passed a node belonging
        // to the old engine to `disconnectNodeOutput`, and AVAudioEngine answers that with
        // an Objective-C exception, which Swift cannot catch and which aborts the process.
        guard !rebuilding else {
            log("Ignoring a re-entrant audio graph rebuild.")
            return false
        }
        rebuilding = true
        defer { rebuilding = false }

        // Coming off the controller route needs the output node's format put back.
        //
        // Disconnecting the four-channel path does not do that on its own: the output node
        // keeps the four-channel input it was given for the controller, so the stereo graph
        // built on top of it is inconsistent. The engine reports itself running and the log
        // looks healthy apart from one line that gives it away — `asked for 2ch @44100;
        // outputNode input 4ch @48000` — while the player refuses to start and every chime
        // after it is discarded. That is what unplugging the controller did: the rumble
        // motors carried on, because they are nothing to do with the audio graph, and the
        // sound stopped, including the sound that should have come out of the Mac.
        //
        // The cure is the explicit main-mixer reconnection at the end of the stereo branch
        // below, with a nil format so the engine takes the format from the hardware rather
        // than keeping the one it had. Replacing the whole engine also cured it and cost
        // four crashes; this does not.
        if started {
            player.stop()
            engine.stop()
            started = false
        }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(reverb)
        engine.disconnectNodeOutput(hapticPlayer)
        engine.disconnectNodeOutput(controllerMixer)

        var controllerDevice: (id: AudioDeviceID, channels: Int)?
        if useController { controllerDevice = controllerOutput() }

        if let controller = controllerDevice,
           let multichannel = Self.discreteFormat(channels: controller.channels,
                                                  sampleRate: AudioDevices.nominalSampleRate(controller.id)) {
            routedToController = true
            setOutputDevice(controller.id)
            format = multichannel
            // Through a mixer of our own with the four-channel format, not the main mixer:
            // the main mixer would fold four channels down by its own rules and smear the
            // haptic pair into the audible one, and the reverb is a stereo unit — neither
            // belongs on this path.
            do {
                try engine.connectNode(player, to: controllerMixer, format: format)
                try engine.connectNode(hapticPlayer, to: controllerMixer, format: format)
                try engine.connectNode(controllerMixer, to: engine.outputNode, format: format)
            } catch {
                // macOS 27 made connect throwing. It is worth using: a failed connection
                // on the four-channel path used to be silent, and the first sign of it was
                // a chime that never arrived.
                log("Could not connect the controller audio graph: \(error.localizedDescription)")
                return false
            }
        } else if useController {
            return false
        } else {
            routedToController = false
            setOutputDevice(nil)
            format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
                ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                 channels: 2, interleaved: false)!
            reverb.loadFactoryPreset(.largeHall)
            reverb.wetDryMix = 14
            do {
                try engine.connectNode(player, to: reverb, format: format)
                try engine.connectNode(reverb, to: engine.mainMixerNode, format: format)
                // The one that matters when coming back from the controller. A nil format
                // means "take it from the hardware", which replaces the four-channel input
                // the output node kept from the controller connection. Without it the
                // player will not start and nothing is heard, on the Mac or anywhere else.
                try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: nil)
            } catch {
                log("Could not connect the Mac audio graph: \(error.localizedDescription)")
                return false
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            log("Audio engine failed to start: \(error.localizedDescription)")
            return false
        }

        guard engine.isRunning else {
            log("Audio engine start returned without error but the engine is not running.")
            logGraph()
            return false
        }

        startPlayers()
        started = true
        log("Audio engine started. Output: \(routedToController ? "controller, 4 channels with haptics" : "system, stereo"), \(Int(format.sampleRate))Hz")
        logGraph()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.verifyRunning() }
        return true
    }

    /// What the engine actually negotiated, as opposed to what it was asked for. A
    /// scheduleBuffer whose format does not match the connection is dropped without an
    /// error, so "the engine started" is not evidence that a sample ever left the machine.
    private func logGraph() {
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let inFormat = engine.outputNode.inputFormat(forBus: 0)
        log("AUDIO GRAPH: asked for \(format.channelCount)ch @\(Int(format.sampleRate)); "
            + "outputNode input \(inFormat.channelCount)ch @\(Int(inFormat.sampleRate)); "
            + "hardware out \(outFormat.channelCount)ch @\(Int(outFormat.sampleRate)); "
            + "playerRunning=\(player.isPlaying) engineRunning=\(engine.isRunning)")
        engine.outputNode.withAudioUnit { unit in
            guard let unit else { return }
            var id: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id, &size)
            let name = AudioDevices.all().first { $0.id == id }?.name ?? "unknown"
            log("AUDIO GRAPH: current device id=\(id) (\(name)) readback status=\(status)")
        }
    }

    /// A format for more than two channels.
    ///
    /// `standardFormatWithSampleRate:channels:` looks like it would do this and does not:
    /// it only handles mono and stereo, and returns nil for anything wider. Four channels
    /// need a layout given explicitly, and the right one here is discrete rather than
    /// quadraphonic — these are four numbered outputs, two of which drive motors, not a
    /// surround field, and labelling them as surround invites CoreAudio to "helpfully"
    /// fold or reposition them.
    public static func discreteFormat(channels: Int, sampleRate: Double) -> AVAudioFormat? {
        guard channels >= 2 else { return nil }
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                             sampleRate: sampleRate > 0 ? sampleRate : 48000,
                             interleaved: false,
                             channelLayout: layout)
    }

    /// Re-checks the route. Cheap enough to call on every connect and disconnect.
    public func refreshRoute() {
        let wanted = controllerOutput() != nil
        guard wanted != routedToController else { return }
        log("Audio route changing — controller audio \(wanted ? "available" : "gone").")
        configureRoute()
    }

    /// nil puts it back on whatever the system default is.
    private func setOutputDevice(_ deviceID: AudioDeviceID?) {
        var id = deviceID ?? AudioDevices.systemDefaultOutput()
        guard id != 0 else { return }
        engine.outputNode.withAudioUnit { unit in
            guard let unit else { return }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                log("Could not set the audio output device (status \(status)).")
            }
        }
    }

    /// `haptics: false` writes only the audible pair, `silent: true` only the haptic pair.
    /// Both exist for the test in the Status tab; everything else uses the defaults.
    /// `cacheKey` names a sound that is always identical, so it is rendered once and kept.
    /// Anything without one is rendered every time, which is right for the test tones and
    /// for the speaker hunt — those are meant to be built fresh.
    public func play(_ tones: [Tone], voice: Voice = .bowl, haptics: Bool = true,
              silent: Bool = false, cacheKey: String? = nil) {
        guard started else { return }

        let signature = "\(format.channelCount)@\(Int(format.sampleRate))"
        if signature != chimeCacheSignature {
            chimeCache.removeAll()
            chimeCacheSignature = signature
        }
        // logNextPlay wants a real render to report on, so it bypasses the cache entirely.
        if let cacheKey = cacheKey, !logNextPlay, let cached = chimeCache[cacheKey] {
            player.scheduleBuffer(cached, at: nil, options: .interrupts, completionHandler: nil)
            return
        }

        let partials = voice.partials
        let tail = (tones.map { $0.start + $0.duration }.max() ?? 1.0) + 0.1
        let frames = AVAudioFrameCount(tail * format.sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames

        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for index in 0..<Int(frames) { data[index] = 0 }
        }
        let left = channels[audibleChannels.left]
        let right = channels[audibleChannels.right]
        let haptic = (haptics && channelCount > hapticChannels.right)
            ? (left: channels[hapticChannels.left], right: channels[hapticChannels.right])
            : nil

        let sampleRate = format.sampleRate

        for tone in tones {
            let startFrame = Int(tone.start * sampleRate)
            let count = Int(tone.duration * sampleRate)

            for step in 0..<count {
                let index = startFrame + step
                guard index >= 0, index < Int(frames) else { continue }
                let time = Double(step) / sampleRate

                // A raised-cosine swell rather than a strike. Its length is the voice's
                // own: the bowl needs a slow onset to sound soft, the bell needs a sharp
                // one to sound struck at all.
                let attackTime = voice.attack
                let attack = time < attackTime ? 0.5 * (1 - cos(.pi * time / attackTime)) : 1.0

                var sample = 0.0
                for partial in partials {
                    let envelope = exp(-time * voice.decayRate * partial.decay)
                    guard envelope > 0.0004 else { continue }
                    let frequency = tone.frequency * partial.ratio
                    // The twin is offset by a fixed number of hertz, not a ratio: beating
                    // is an absolute-frequency effect, so a fixed ratio would make high
                    // partials flutter and low ones barely move.
                    sample += partial.amplitude * envelope * sin(2 * .pi * frequency * time)
                    sample += partial.amplitude * 0.85 * envelope
                        * sin(2 * .pi * (frequency + partial.beat) * time)
                }

                let value = silent ? 0 : Float(sample * 0.085 * tone.amplitude * attack)
                left[index] += value
                right[index] += value

                // The actuators are voice coils: small speakers, with nothing useful above
                // a couple of hundred hertz. So the haptic channel is not the tone itself
                // but a low sine carrying the tone's own envelope — it rises and falls with
                // what you are hearing, which is what makes it feel like part of the sound
                // rather than a separate buzz. Its pitch follows the note, bounded, so a
                // low chime is felt lower than a high one.
                if let haptic = haptic {
                    let carrier = min(max(tone.frequency / 3.0, 45.0), 140.0)
                    let envelope = exp(-time * voice.decayRate) * attack
                    let pulse = Float(sin(2 * .pi * carrier * time) * envelope * tone.amplitude * 0.55)
                    haptic.left[index] += pulse
                    haptic.right[index] += pulse
                }
            }
        }

        // Guard against summed partials clipping. Only the audible pair is scaled: the
        // haptic channels are a single sine and cannot clip on their own, and quietening
        // them because the chime was loud would weaken the very thing being asked for.
        var peak: Float = 0
        for index in 0..<Int(frames) { peak = max(peak, abs(left[index])) }
        if peak > 0.95 {
            let scale = 0.95 / peak
            for index in 0..<Int(frames) {
                left[index] *= scale
                right[index] *= scale
            }
        }

        if logNextPlay {
            logNextPlay = false
            var audiblePeak: Float = 0
            var hapticPeak: Float = 0
            for index in 0..<Int(frames) {
                audiblePeak = max(audiblePeak, abs(left[index]))
                if let haptic = haptic { hapticPeak = max(hapticPeak, abs(haptic.left[index])) }
            }
            let matches = buffer.format.channelCount == format.channelCount
                && buffer.format.sampleRate == format.sampleRate
            log("AUDIO PLAY: \(frames) frames, \(buffer.format.channelCount)ch @\(Int(buffer.format.sampleRate)), "
                + "audiblePeak=\(String(format: "%.3f", audiblePeak)) "
                + "hapticPeak=\(String(format: "%.3f", hapticPeak)) "
                + "formatMatchesConnection=\(matches)")
        }
        if let cacheKey = cacheKey {
            // A hard cap rather than a least-recently-used list: the only thing that grows
            // this is one entry per item in the library, and starting again is cheaper than
            // keeping track of which of a hundred short buffers was used least recently.
            if chimeCache.count >= chimeCacheLimit { chimeCache.removeAll() }
            chimeCache[cacheKey] = buffer
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// Set to have the next play logged in full. One-shot, so the log is not flooded.
    public var logNextPlay = false

    /// Which pair of channels a test tone goes to.
    public enum TestTarget {
        /// Front Left and Front Right — the headphone jack or the controller's own
        /// speaker, depending on the output path byte in the HID report.
        case audible
        /// Back Left and Back Right — the voice coils in the grips.
        case haptic
    }

    /// A plain sine straight onto one pair of channels, at whatever level is asked for.
    ///
    /// This deliberately bypasses `play` and its 0.085 house level. That level is right
    /// for a chime on the Mac's speakers and quite wrong for finding out whether a small
    /// speaker in a controller makes any sound at all — the first attempt at this test
    /// put a peak of 0.099 on the wire and concluded the hardware was silent. A test
    /// instrument should be unmistakable, so this one is loud, steady and continuous:
    /// a sustained tone cannot be confused with the click the actuators make when the
    /// audio configuration changes, which a short chime can.
    public func playTestTone(frequency: Double, duration: Double, amplitude: Double, target: TestTarget) {
        guard started else { return }
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard let channels = buffer.floatChannelData else { return }

        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for index in 0..<Int(frames) { data[index] = 0 }
        }

        let pair: (Int, Int)
        switch target {
        case .audible: pair = (audibleChannels.left, audibleChannels.right)
        case .haptic:
            guard channelCount > hapticChannels.right else { return }
            pair = (hapticChannels.left, hapticChannels.right)
        }
        let left = channels[pair.0]
        let right = channels[pair.1]

        // Ten milliseconds of fade at each end. Without it a loud sine starting at full
        // amplitude clicks, and a click is exactly the thing this test must not produce.
        let fade = min(0.01 * sampleRate, Double(frames) / 2)
        for index in 0..<Int(frames) {
            let time = Double(index) / sampleRate
            var gain = 1.0
            if Double(index) < fade { gain = Double(index) / fade }
            let fromEnd = Double(Int(frames) - index)
            if fromEnd < fade { gain = min(gain, fromEnd / fade) }
            let value = Float(sin(2 * .pi * frequency * time) * amplitude * gain)
            left[index] = value
            right[index] = value
        }

        log("AUDIO TEST TONE: \(Int(frequency))Hz for \(String(format: "%.1f", duration))s "
            + "at amplitude \(String(format: "%.2f", amplitude)) on "
            + "\(target == .audible ? "Front L/R (channels 1-2)" : "Back L/R (channels 3-4)")")
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// The shape of a haptic, described as a movement rather than a level.
    ///
    /// The actuators are voice coils with nothing useful much above two hundred hertz, so
    /// there is not a lot of room — but there is more than one dimension in it. Pitch,
    /// whether the pitch rises or falls, how sharply it starts and how fast it dies are all
    /// plainly distinguishable by hand, and between them they are enough to make one event
    /// feel unlike another instead of every one being the same tap at a different volume.
    public struct Haptic {
        /// Hertz at the start and at the end. Equal values hold a pitch; different ones
        /// glide, and a glide is the most legible of these by a distance — rising and
        /// falling are told apart instantly and without being learned.
        public var from: Double
        public var to: Double
        public var strength: Double
        public var duration: TimeInterval
        /// Seconds to reach full. Short is a knock, long is a swell.
        public var attack: Double
        /// Exponential decay rate. 0 holds the level for the whole duration.
        public var decay: Double
        /// 0 is smooth. Above that the level is modulated a few times a second, which is
        /// felt as roughness and reads as something being wrong.
        public var roughness: Double = 0

        public init(from: Double, to: Double? = nil, strength: Double, duration: TimeInterval,
             attack: Double = 0.004, decay: Double = 20, roughness: Double = 0) {
            self.from = from
            self.to = to ?? from
            self.strength = strength
            self.duration = duration
            self.attack = attack
            self.decay = decay
            self.roughness = roughness
        }
    }

    /// Plays a haptic through the audio path rather than the rumble motors.
    ///
    /// This exists so that nothing has to send valid_flag0 bits 0 and 1 while the audio
    /// route is up. Those bits put the voice coils into classic-rumble emulation, and the
    /// controller stops answering the audio channels once they are set.
    ///
    /// It goes to its own player node. Buffers scheduled onto a player queue behind
    /// whatever is already on it, so sharing the chime's player would have made every
    /// haptic arrive after the sound it belonged to rather than with it.
    ///
    /// `balance` sends it to one grip more than the other: −1 left only, 0 both equally
    /// (the default, and all Muteny uses), 1 right only. Equal-power, so a centred pulse
    /// is as strong as it always was.
    public func hapticPulse(_ haptic: Haptic, balance: Double = 0) {
        guard started, Int(format.channelCount) > hapticChannels.right else { return }
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(haptic.duration * sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard let channels = buffer.floatChannelData else { return }

        let channelCount = Int(format.channelCount)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for index in 0..<Int(frames) { data[index] = 0 }
        }
        let left = channels[hapticChannels.left]
        let right = channels[hapticChannels.right]

        // The phase is integrated rather than computed from the frequency at each sample.
        // Working it out as sin(2 pi f(t) t) with a changing f jumps the waveform every
        // time f moves, and the jumps are heard and felt as a rattle over the glide.
        var phase = 0.0
        let total = Double(frames)
        let release = min(0.006 * sampleRate, total / 3)
        // Centred gives 1 on both sides, as before; a full pan gives √2 on one side and 0 on
        // the other — the same total power.
        let angle = (max(-1, min(1, balance)) + 1) * .pi / 4
        let leftGain = Float(cos(angle) * 2.0.squareRoot())
        let rightGain = Float(sin(angle) * 2.0.squareRoot())

        for index in 0..<Int(frames) {
            let time = Double(index) / sampleRate
            let progress = Double(index) / total
            let frequency = haptic.from + (haptic.to - haptic.from) * progress
            phase += 2 * .pi * frequency / sampleRate

            var envelope = min(time / max(haptic.attack, 0.0005), 1.0)
            if haptic.decay > 0 { envelope *= exp(-time * haptic.decay) }
            if haptic.roughness > 0 {
                let tremolo = 0.5 + 0.5 * sin(2 * .pi * 19.0 * time)
                envelope *= (1 - haptic.roughness) + haptic.roughness * tremolo
            }
            // Ease the last few milliseconds to zero, or the buffer ends on a step and the
            // actuator clicks.
            let remaining = total - Double(index)
            if remaining < release { envelope *= remaining / release }

            let value = Float(sin(phase) * envelope * haptic.strength)
            left[index] = value * leftGain
            right[index] = value * rightGain
        }

        hapticPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
}

// MARK: - The launcher's ambience

extension Chime {
    /// A soft pad that plays while the launcher is open — the Playnite idea, that a
    /// launcher is a place rather than a list. Three notes of a D chord, each a pair of
    /// sines a hertz and a half apart so they breathe against each other, under a slow
    /// swell. Built as one four-second loop: every frequency in it is a multiple of a
    /// quarter-hertz, so the loop point is silent — no click, no matter how long it plays.
    ///
    /// It is quiet on purpose. It sits under speech and under the chimes, and it fades in
    /// and out rather than starting and stopping, so it never announces itself.
    public func startPad() {
        guard !padIsUp else { return }
        guard preparePadEngine() else {
            log("Ambience: the pad engine would not start; the library will be silent under the speech.")
            return
        }
        padIsUp = true
        guard let buffer = cachedPadLoop() else { return }
        pad.volume = 0
        pad.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts], completionHandler: nil)
        // The same guard the chime players get: `playAudio()` raises rather than returning
        // an error on a node with no output connection, and a raise here is not catchable.
        if !pad.isPlaying,
           pad.engine === padEngine,
           !padEngine.outputConnectionPoints(for: pad, outputBus: 0).isEmpty {
            do { try pad.playAudio() } catch {
                log("Ambience: the pad player would not start — \(error.localizedDescription)")
            }
        }
        // Slower in than it used to be. A pad that arrives is a thing that happened; one
        // that is simply there by the time you notice it is a place.
        fadePad(to: 0.125, over: 1.6)
    }

    public func stopPad() {
        guard padIsUp else { return }
        padIsUp = false
        fadePad(to: 0, over: 1.1) { [weak self] in
            self?.pad.stop()
        }
    }

    /// Brings the pad's engine up, once, and keeps it. Its output device is never set, so
    /// it follows the system default — which is exactly the behaviour wanted here: plug in
    /// headphones and the music follows them, plug in the controller and it does not.
    private func preparePadEngine() -> Bool {
        if padEngine.isRunning { return true }
        if !padAttached {
            padEngine.attach(pad)
            padAttached = true
            padObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: padEngine, queue: .main) { [weak self] note in
                    guard let self = self, (note.object as AnyObject?) === self.padEngine else { return }
                    // Off the callout before touching the graph, for the reason written at
                    // length on the main engine's observer: the notification arrives while
                    // the engine is part-way through its own reconfiguration, and taking the
                    // graph apart from inside it raises.
                    DispatchQueue.main.async { [weak self] in self?.rebuildPadEngine() }
                }
        }
        do {
            try padEngine.connectNode(pad, to: padEngine.mainMixerNode, format: padFormat)
            try padEngine.start()
        } catch {
            log("Ambience: could not start the pad engine — \(error.localizedDescription)")
            return false
        }
        return padEngine.isRunning
    }

    /// The default output device changed underneath the music. Put it back on the new one,
    /// from the top, rather than trying to patch a graph that has already moved.
    private func rebuildPadEngine() {
        let wasUp = padIsUp
        padFade?.invalidate()
        padFade = nil
        pad.stop()
        padEngine.stop()
        padIsUp = false
        log("Ambience: the default output changed; rebuilding the pad engine (was playing: \(wasUp)).")
        guard wasUp else { return }
        startPad()
    }

    private func cachedPadLoop() -> AVAudioPCMBuffer? {
        if let buffer = padBuffer { return buffer }
        padBuffer = renderPadLoop()
        return padBuffer
    }

    private func fadePad(to target: Float, over seconds: TimeInterval, then completion: (() -> Void)? = nil) {
        padFade?.invalidate()
        let steps = max(Int(seconds / 0.03), 1)
        let start = pad.volume
        var step = 0
        padFade = Timer.common(0.03, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            step += 1
            let progress = Float(step) / Float(steps)
            self.pad.volume = start + (target - start) * min(progress, 1)
            if step >= steps {
                timer.invalidate()
                self.padFade = nil
                completion?()
            }
        }
    }

    private func renderPadLoop() -> AVAudioPCMBuffer? {
        // Eight seconds rather than four. The old loop was short enough to be recognised as
        // a loop, which is the one thing ambience must not be.
        let seconds = 8.0
        let sampleRate = padFormat.sampleRate
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: padFormat, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        let channelCount = Int(padFormat.channelCount)
        for channel in 0..<channelCount {
            for index in 0..<Int(frames) { channels[channel][index] = 0 }
        }

        // Everything below — every pitch, every detune, every swell rate — is a whole
        // multiple of an eighth of a hertz, which is one cycle per loop. That is what makes
        // the loop point silent: every voice is at exactly the same place in its cycle at
        // the end as at the start, so there is nothing to click.
        //
        // The chord is D, E, F sharp and A: a D major with the second left in and the third
        // kept low and soft. An open chord with a note in it that does not resolve is what
        // makes a pad sound like weather rather than like music, and it has no strong sense
        // of major or minor to argue with whatever is on screen.
        //
        // Each voice is a pair a fraction of a hertz apart, and **every pair beats at a
        // different rate** — that is the change that matters. One detune across the whole
        // chord gives a single throb you start counting. Six rates that never line up give
        // a shimmer you cannot follow, which is the sound of a pad slowly moving.
        struct Voice {
            let frequency: Double
            let amplitude: Double
            /// Hertz between the pair. Multiples of an eighth of a hertz.
            let detune: Double
            /// How fast this voice breathes, and where in the breath it starts. The phases
            /// are spread so the voices swell one after another rather than together.
            let swellRate: Double
            let swellPhase: Double
        }

        let voices = [
            // D2 and D3: the floor. Nearly still, because a low note that moves is a wobble.
            Voice(frequency: 73.375, amplitude: 0.85, detune: 0.125, swellRate: 0.125, swellPhase: 0.0),
            Voice(frequency: 146.875, amplitude: 0.70, detune: 0.250, swellRate: 0.125, swellPhase: 0.8),
            // A3: the fifth, and the voice that carries most of the warmth.
            Voice(frequency: 220.000, amplitude: 0.52, detune: 0.625, swellRate: 0.250, swellPhase: 1.9),
            // D4.
            Voice(frequency: 293.750, amplitude: 0.44, detune: 0.750, swellRate: 0.250, swellPhase: 3.1),
            // E4 — the second. Quiet, and the reason the chord never settles.
            Voice(frequency: 329.625, amplitude: 0.26, detune: 0.875, swellRate: 0.375, swellPhase: 4.4),
            // F sharp 4 — the third, softer still, so the chord is coloured rather than named.
            Voice(frequency: 370.000, amplitude: 0.20, detune: 1.125, swellRate: 0.375, swellPhase: 0.5),
            // A4 and D5: air above the chord. These breathe most, and nearly vanish between
            // breaths, which is where the sense of distance comes from.
            Voice(frequency: 440.000, amplitude: 0.17, detune: 1.375, swellRate: 0.500, swellPhase: 2.6),
            Voice(frequency: 587.500, amplitude: 0.11, detune: 1.625, swellRate: 0.500, swellPhase: 5.0)
        ]

        // One breath across the whole loop, under all the others.
        let globalRate = 0.125
        // Normalised against the loudest the chord can be, then taken well down: this plays
        // under speech, and speech is the thing that matters.
        let peak = voices.reduce(0.0) { $0 + $1.amplitude * 1.9 }
        let scale = 0.62 / max(peak, 0.0001)

        for index in 0..<Int(frames) {
            let time = Double(index) / sampleRate
            let global = 0.80 + 0.20 * sin(2 * .pi * globalRate * time - .pi / 2)
            var sample = 0.0
            for voice in voices {
                // Never all the way to silence: a voice that switches off leaves a hole in
                // the chord, and the hole is audible where the swell is not.
                let swell = 0.55 + 0.45 * sin(2 * .pi * voice.swellRate * time + voice.swellPhase)
                let level = voice.amplitude * swell
                sample += level * sin(2 * .pi * voice.frequency * time)
                sample += level * 0.9 * sin(2 * .pi * (voice.frequency + voice.detune) * time)
            }
            let value = Float(sample * scale * global)
            // Plain stereo: this engine is on the Mac, so there is no haptic pair here and
            // never was anything useful to put in one. An eight-second hum in the hands is
            // not ambience.
            channels[0][index] = value
            if channelCount > 1 { channels[1][index] = value }
        }
        return buffer
    }
}

public enum AudioDevices {
    public static func all() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let name else { return nil }
            return (id: id, name: name.takeUnretainedValue() as String)
        }
    }

    public static func systemDefaultOutput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    public static func find(nameContaining fragment: String) -> AudioDeviceID? {
        all().first { $0.name.localizedCaseInsensitiveContains(fragment) }?.id
    }

    public static func logAll() {
        log("Audio devices seen: \(all().map { $0.name }.joined(separator: " | "))")
    }

    /// Four-character codes come back as a UInt32; printed as text they are readable
    /// ("usb ", "bltn", "blue").
    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }

    public static func transport(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "?" }
        return fourCC(value)
    }

    /// Channels per stream on one scope. The DualSense's haptic actuators are presented as
    /// extra output channels on its USB audio device rather than as anything HID, so the
    /// channel count and its split across streams is what decides whether haptics are
    /// reachable at all — and it is not something to assume.
    public static func channels(_ id: AudioDeviceID, input: Bool) -> [Int] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    public static func channelName(_ id: AudioDeviceID, channel: UInt32) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyElementName,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: channel)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        let string = name.takeUnretainedValue() as String
        return string.isEmpty ? nil : string
    }

    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// Dumps everything needed to decide how to talk to the controller's audio side.
    public static func describeDualSense() {
        let candidates = all().filter { $0.name.localizedCaseInsensitiveContains("DualSense")
                                     || $0.name.localizedCaseInsensitiveContains("Wireless Controller") }
        guard !candidates.isEmpty else {
            log("AUDIO PROBE: no DualSense audio device present.")
            return
        }
        for device in candidates {
            let out = channels(device.id, input: false)
            let totalOut = out.reduce(0, +)
            log("AUDIO PROBE: \(device.name) id=\(device.id) transport=\(transport(device.id)) "
                + "rate=\(nominalSampleRate(device.id)) "
                + "outStreams=\(out) totalOut=\(totalOut) in=\(channels(device.id, input: true))")
            guard totalOut > 0 else { continue }
            for channel in 1...UInt32(totalOut) {
                log("AUDIO PROBE:   out channel \(channel): \(channelName(device.id, channel: channel) ?? "unnamed")")
            }
        }
    }
}
