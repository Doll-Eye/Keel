import Foundation

extension Timer {
    /// A scheduled timer added in the common run-loop modes. `Timer.scheduledTimer` uses
    /// the default mode only, and the main run loop leaves that mode whenever AppKit is
    /// tracking a menu, a modal panel or a resize — during which every one of the app's
    /// safety timers silently stops. The mode-exit guarantees this app leans on have to
    /// keep running exactly then.
    @discardableResult
    public static func common(_ interval: TimeInterval, repeats: Bool,
                       _ block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// Plain-text logging to ~/Library/Application Support/Muteny/logs, next to
/// bindings.json, so behaviour can be inspected without watching the screen.
///
/// It used to write into ~/Documents/Muteny, which was the source folder at the time.
/// The source has moved and Documents is TCC-gated for a non-sandboxed app anyway; a
/// denied grant there meant every log line was thrown away with no indication, and every
/// diagnosis in this project has come from that log.
public final class AppLog {
    public static let shared = AppLog()
    private var handle: FileHandle?
    public private(set) var url: URL?
    private let queue = DispatchQueue(label: "muteny.log")

    /// The folder under Application Support that holds this app's logs, and the log file's
    /// prefix. Muteny by default; another app sets it as the first thing it does, before
    /// anything logs — `shared` is created on first use and reads it once.
    public static var appName = "Muteny"

    public static var directory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("\(appName)/logs", isDirectory: true)
    }

    private init() {
        let directory = Self.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let fileURL = directory.appendingPathComponent("\(Self.appName.lowercased().replacingOccurrences(of: " ", with: "-"))-\(formatter.string(from: Date())).log")
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: fileURL)
            url = fileURL
        } catch {
            handle = nil
        }
    }

    public func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [weak self] in
            if let data = line.data(using: .utf8) { self?.handle?.write(data) }
        }
    }
}

public func log(_ message: String) { AppLog.shared.write(message) }
