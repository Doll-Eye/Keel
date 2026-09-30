import Foundation
import AppKit
import AVFoundation
import CoreServices

/// Speech, by three routes, in descending order of how well they work.
///
/// **1. VoiceOver's own AppleScript interface.** `tell application "VoiceOver" to output`
/// makes VoiceOver say something regardless of which app is frontmost. That last part is
/// the whole reason it is first: Muteny is a menu-bar app and is deliberately never in
/// front while you are holding the controller.
///
/// **2. An accessibility announcement.** macOS only delivers these from the frontmost
/// app, and only when posted to a real window — so this covers the launcher and the
/// settings window and nothing else.
///
/// **3. Muteny's own synthesiser.** Always works, but it is a second voice talking over
/// your screen reader, so it is the last resort rather than the default.
///
/// Route 1 needs two things switched on once: "Allow VoiceOver to be controlled with
/// AppleScript" in VoiceOver Utility under General, and permission for Muteny to control
/// VoiceOver, which macOS asks for the first time it is tried.
public enum Announcer {

    public enum Route: String {
        case voiceOverScript = "VoiceOver (AppleScript)"
        case accessibilityAnnouncement = "accessibility announcement"
        case builtInSynthesiser = "Muteny's own voice"
        case none = "nothing available"
    }

    private static let fallback = AVSpeechSynthesizer()
    private static let scriptQueue = DispatchQueue(label: "muteny.voiceover.script")

    /// nil until tried. Set false once VoiceOver scripting has been shown not to work, so
    /// a disabled setting does not mean an AppleScript attempt before every single phrase.
    private static var scriptWorks: Bool?
    private static var reportedScriptFailure = false

    /// When route 1 last refused. The refusal is not permanent — permission can be granted
    /// while Muteny is running, and every rebuild from Xcode revokes it again — so the
    /// route is retried on a slow timer rather than written off for the session. Without
    /// this, granting the permission has no effect until Muteny is restarted, which is not
    /// something anyone would think to do.
    private static var scriptRefusedAt: Date?
    private static let retryInterval: TimeInterval = 30

    private static var shouldTryScript: Bool {
        if scriptWorks == true { return true }
        guard let refusedAt = scriptRefusedAt else { return true }
        return Date().timeIntervalSince(refusedAt) > retryInterval
    }

    public private(set) static var lastRoute: Route = .none

    public static var isVoiceOverRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    /// Whether route 1 is believed to be available. nil means untested.
    public static var voiceOverScriptingAvailable: Bool? { scriptWorks }

    public static func say(_ text: String, interrupting: Bool = true) {
        guard !text.isEmpty else { return }
        // **VoiceOver on: work with VoiceOver. VoiceOver off: say nothing.**
        //
        // The owner's rule, 22 September 2026, and it is the right one. A synthesised voice
        // reading the interface at somebody who can see it is not accessibility, it is an
        // app talking to itself — and this one is for sighted players too. Everything Muteny
        // needs to say without VoiceOver it says in a channel that suits both: a chime, a
        // haptic, a row on screen.
        guard isVoiceOverRunning else {
            lastRoute = .none
            return
        }

        if isVoiceOverRunning && shouldTryScript {
            scriptQueue.async {
                if speakViaVoiceOver(text) {
                    if scriptWorks != true { log("VoiceOver speech is working again.") }
                    scriptWorks = true
                    scriptRefusedAt = nil
                    reportedScriptFailure = false
                    lastRoute = .voiceOverScript
                } else {
                    scriptWorks = false
                    scriptRefusedAt = Date()
                    DispatchQueue.main.async { sayWithoutVoiceOverScript(text, interrupting: interrupting) }
                }
            }
            return
        }

        sayWithoutVoiceOverScript(text, interrupting: interrupting)
    }

    /// Re-tests route 1 — after the user has changed the VoiceOver setting, say.
    public static func resetRouteDetection() {
        scriptWorks = nil
        scriptRefusedAt = nil
        reportedScriptFailure = false
        log("Speech route detection reset.")
        requestVoiceOverPermission()
    }

    /// Asks macOS up front whether Muteny may drive VoiceOver, and lets it put the consent
    /// prompt on screen while the user is here to answer it. Left until the first chime,
    /// that prompt appears behind whatever you were doing — which is how this silently ends
    /// up on the fallback voice after every rebuild.
    ///
    /// Returns true if already permitted, false if refused, nil if unanswered or VoiceOver
    /// is not running.
    /// The same check, off the main thread.
    ///
    /// `AEDeterminePermissionToAutomateTarget` with `askUser` **blocks until the consent
    /// dialog is answered** — and it was being called from `start()`, on the main thread, at
    /// launch. On 17 September 2026 that dialog was pending, and Muteny sat in a semaphore
    /// wait for its entire lifetime: no run loop, no timers, no controller, no speech, no
    /// log line saying why, and VoiceOver timing out every time it asked Muteny a question.
    /// The answer to "may I drive VoiceOver" is worth knowing but never worth the whole app.
    public static func requestVoiceOverPermissionInBackground() {
        DispatchQueue.global(qos: .utility).async {
            let result = requestVoiceOverPermission(askUser: true)
            DispatchQueue.main.async {
                log("Automation permission for VoiceOver (asked in the background): "
                    + (result == true ? "granted" : result == false ? "refused" : "unanswered or unavailable"))
            }
        }
    }

    @discardableResult
    public static func requestVoiceOverPermission(askUser: Bool = true) -> Bool? {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.VoiceOver")
        guard let descriptor = target.aeDesc else {
            log("Automation permission for VoiceOver: could not address VoiceOver.")
            return nil
        }
        let wildcard = AEEventClass(typeWildCard)
        let status = AEDeterminePermissionToAutomateTarget(
            descriptor, wildcard, AEEventID(typeWildCard), askUser)

        switch status {
        case noErr:
            log("Automation permission for VoiceOver: granted.")
            scriptRefusedAt = nil
            return true
        case OSStatus(errAEEventNotPermitted):
            log("Automation permission for VoiceOver: refused. System Settings, Privacy and "
                + "Security, Automation, Muteny.")
            return false
        case OSStatus(errAEEventWouldRequireUserConsent):
            log("Automation permission for VoiceOver: waiting on the consent prompt.")
            return nil
        case OSStatus(procNotFound):
            log("Automation permission for VoiceOver: VoiceOver is not running.")
            return nil
        default:
            log("Automation permission for VoiceOver: unexpected status \(status).")
            return nil
        }
    }

    private static func sayWithoutVoiceOverScript(_ text: String, interrupting: Bool) {
        if isVoiceOverRunning, NSApp.isActive, let window = NSApp.keyWindow ?? NSApp.mainWindow {
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: (interrupting ? NSAccessibilityPriorityLevel.high
                                             : NSAccessibilityPriorityLevel.medium).rawValue
                ])
            lastRoute = .accessibilityAnnouncement
            return
        }

        if interrupting { fallback.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.55
        fallback.speak(utterance)
        lastRoute = .builtInSynthesiser
    }

    private static func speakViaVoiceOver(_ text: String) -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"VoiceOver\" to output \"\(escaped)\""

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)

        guard let error = error else { return true }

        if !reportedScriptFailure {
            reportedScriptFailure = true
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            switch code {
            case -1743:
                log("VoiceOver scripting refused: Muteny has not been allowed to control VoiceOver. "
                    + "System Settings, Privacy and Security, Automation.")
            case -1728, -1708:
                log("VoiceOver scripting is switched off: tick \"Allow VoiceOver to be controlled with "
                    + "AppleScript\" in VoiceOver Utility, General.")
            default:
                log("VoiceOver scripting failed (\(code)): \(message)")
            }
            log("Falling back to Muteny's own voice.")
        }
        return false
    }
}
