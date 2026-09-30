# Keel

The shared Swift package Muteny and Flotilla are both built on — named for the backbone of a
hull. It holds the code both apps need and nothing app-specific:

    Sources/Keel/
      DualSense.swift   HID layer: report decoding, seize/release, output reports (rumble,
                        triggers, lights, audio config), shake and battery detection
      Announcer.swift   speech: VoiceOver AppleScript → accessibility announcement →
                        synthesiser, with permission request and retry
      Sound.swift       Chime synth (three voices), routing (Mac / controller 4-channel),
                        launcher pad, AudioDevices
      Feedback.swift    what the user hears and feels: chimes, pulses, earcons, presence,
                        battery, escape
      AppLog.swift      log + Timer.common

Rules carried over from Muteny apply in full here — the HID-callback rule, the AVAudioEngine
rules, Timer.common, valid_flag0 — see Muteny's CLAUDE.md; this package is where most of that
hard-won code now lives. API is `public`; when an app needs a symbol the compiler names it and
the fix is adding `public` at that declaration. Platform floor is macOS 27 because Sound uses
27-only AVAudioEngine API. Build standalone with `swift build` (set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if xcode-select points at the CLT).
