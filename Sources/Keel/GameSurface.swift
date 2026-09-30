import AppKit

/// Whether a game or stream is filling the screen — PS Remote Play, Shadow, GeForce NOW,
/// Steam's Big Picture, a full-screen game.
///
/// Decided by the window server, never by activation: streaming processes can be invisible
/// to activation entirely (Steam Remote Play's `steamstreamingclient` never appears in
/// `runningApplications`, and macOS reports another app as frontmost while it streams —
/// measured 17 September 2026). Any window covering at least 85 % of the screen, at the
/// normal layer or the full-screen backing layer, that is not the desktop's own chrome and
/// not one of this family of apps, counts.
///
/// Why it exists: the PS button belongs to whatever is being played. Inside a Remote Play
/// session it opens the PlayStation's home; inside Big Picture it is Steam's guide button.
/// The launcher must only answer it when nothing like that is on screen.
public enum GameSurface {
    public static func isOnScreen() -> Bool { onScreenOwner() != nil }

    /// Which app is filling the screen, or nil if nothing is. Same test as `isOnScreen`;
    /// the name is worth having so a log can say *what* is playing rather than only that
    /// something is.
    public static func onScreenOwner() -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
        let threshold = screen.width * screen.height * 0.85
        for window in list {
            let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 || layer == -1 else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let area = ((bounds?["Width"] as? Double) ?? 0) * ((bounds?["Height"] as? Double) ?? 0)
            guard area >= threshold else { continue }
            let owner = ((window[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
            if owner == "finder" || owner == "dock" || owner == "window server"
                || owner == "windowmanager" || owner == "wallpaper" { continue }
            if owner == "muteny" || owner == "flotilla" { continue }
            return (window[kCGWindowOwnerName as String] as? String) ?? "a game"
        }
        return nil
    }
}
