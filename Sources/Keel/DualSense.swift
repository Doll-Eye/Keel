import Foundation
import IOKit
import IOKit.hid

// MARK: - Buttons

public enum DSButton: String, CaseIterable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case square, cross, circle, triangle
    case l1, r1, l2, r2
    case create, options, l3, r3
    case ps, touchpad, mute
    case touchTap, swipeLeft, swipeRight, swipeUp, swipeDown

    public var displayName: String {
        switch self {
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .square: return "Square"
        case .cross: return "Cross"
        case .circle: return "Circle"
        case .triangle: return "Triangle"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .create: return "Create"
        case .options: return "Options"
        case .l3: return "L3"
        case .r3: return "R3"
        case .ps: return "PS"
        case .touchpad: return "Touchpad"
        case .mute: return "Mute"
        case .touchTap: return "Touchpad tap"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        }
    }
}

/// Decodes the three button bytes. Offsets verified against live hardware on
/// 2026-09-14: over Bluetooth (report 0x31) they are bytes 9, 10, 11; over USB
/// (report 0x01) they are 8, 9, 10.
public struct ButtonState {
    public var pressed: Set<DSButton> = []

    /// Stick axes, -1 to 1. Y is positive downwards so it matches screen coordinates
    /// rather than the controller's own convention — every consumer of these wants
    /// screen coordinates, so the flip belongs here once rather than at each call site.
    public var leftX = 0.0, leftY = 0.0
    public var rightX = 0.0, rightY = 0.0
    /// Analogue triggers, 0 to 1.
    public var l2 = 0.0, r2 = 0.0
    /// Battery, 0-100, and whether it is on charge. The report carries it in tenths.
    /// `batteryKnown` is false when the report was too short to hold the status byte or
    /// the controller reported a fault code — 0 percent must never be announced, or acted
    /// on as a low-battery warning, when the truth is that nothing was read.
    public var batteryPercent = 0
    public var charging = false
    public var batteryKnown = false
    /// Accelerometer in g, so a resting controller reads about 1.0 in magnitude.
    public var accelX = 0.0, accelY = 0.0, accelZ = 0.0

    public init() {}

    /// Failable on purpose. A report Muteny cannot decode used to produce an empty state,
    /// which the caller then stored — so the next good report saw every held button as
    /// newly pressed and fired its binding again. A single d-pad press could move the
    /// launcher two items. Undecodable now means "no information", not "nothing is held".
    public init?(reportID: UInt32, bytes: [UInt8]) {
        let base: Int
        switch reportID {
        case 0x31: base = 9
        case 0x01: base = 8
        default: return nil
        }
        guard bytes.count > base + 2 else { return nil }

        // The sticks sit seven bytes ahead of the button block and the triggers three,
        // in both transports — the Bluetooth report is the USB one shifted by one, so a
        // single offset from the verified button base covers both.
        let sticks = base - 7
        if sticks >= 0, bytes.count > base - 2 {
            leftX = Self.axis(bytes[sticks])
            leftY = Self.axis(bytes[sticks + 1])
            rightX = Self.axis(bytes[sticks + 2])
            rightY = Self.axis(bytes[sticks + 3])
            l2 = Double(bytes[base - 3]) / 255.0
            r2 = Double(bytes[base - 2]) / 255.0
        }

        // Accelerometer: three little-endian Int16s starting fourteen bytes past the
        // button base, at roughly 8192 counts per g.
        //
        // Measured, not assumed. The layout from the button base is: buttons [0...3],
        // four reserved [4...7], gyro [8...13], accelerometer [14...19], timestamp
        // [20...23]. With the controller lying still, base+8 reads (-2, -2, -4) — the
        // gyro at rest — and base+14 reads (0.25, 0.87, 0.31), magnitude 0.955g, stable
        // across samples. That is gravity, so base+14 is the accelerometer.
        //
        // This was base+13, a fencepost off the end of the gyro. It mixed the gyro's
        // last byte into the accelerometer's first, so a controller sitting on a desk
        // read 4-5g of noise and fired a shake every two seconds — the cooldown was the
        // only thing holding it back. Any offset here must be checked by the rule above:
        // at rest the magnitude is 1.0, and it is 1.0 at no other offset.
        let accel = base + 14
        if bytes.count > accel + 5 {
            accelX = Double(Self.int16(bytes, at: accel)) / 8192.0
            accelY = Double(Self.int16(bytes, at: accel + 2)) / 8192.0
            accelZ = Double(Self.int16(bytes, at: accel + 4)) / 8192.0
        }

        // Battery: forty-five bytes past the button base — the status byte that follows
        // the two touch points and twelve reserved bytes.
        //
        // Measured too. base+44 was being read, but across samples it changed 0x33 ->
        // 0x34 while its neighbours held the pattern of a second timestamp, and its high
        // nibble was 3, which is not a defined charge state. base+45 read 0x29 in every
        // sample: level 9, state 2 (full) on a controller sitting on USB power. Stable
        // and plausible where base+44 was neither.
        //
        // The nibble meanings are from the open-source drivers, not verified here: low
        // nibble is level in ten-percent steps, high nibble is charge state — 0
        // discharging, 1 charging, 2 full, and 0xA, 0xB, 0xF fault codes that must not
        // be read as a level. The +5 centres the step the way the driver does.
        let battery = base + 45
        if bytes.count > battery {
            let raw = bytes[battery]
            let level = Int(raw & 0x0F)
            let state = (raw >> 4) & 0x0F
            switch state {
            case 0, 1:
                batteryPercent = min(level * 10 + 5, 100)
                charging = state == 1
                batteryKnown = true
            case 2:
                batteryPercent = 100
                charging = true
                batteryKnown = true
            default:
                // A fault code. Say nothing rather than a wrong number.
                batteryKnown = false
            }
        }

        let b0 = bytes[base], b1 = bytes[base + 1], b2 = bytes[base + 2]

        // Low nibble of the first button byte is a d-pad hat, 8 means centred.
        switch b0 & 0x0F {
        case 0: pressed.insert(.dpadUp)
        case 1: pressed.formUnion([.dpadUp, .dpadRight])
        case 2: pressed.insert(.dpadRight)
        case 3: pressed.formUnion([.dpadDown, .dpadRight])
        case 4: pressed.insert(.dpadDown)
        case 5: pressed.formUnion([.dpadDown, .dpadLeft])
        case 6: pressed.insert(.dpadLeft)
        case 7: pressed.formUnion([.dpadUp, .dpadLeft])
        default: break
        }

        if b0 & 0x10 != 0 { pressed.insert(.square) }
        if b0 & 0x20 != 0 { pressed.insert(.cross) }
        if b0 & 0x40 != 0 { pressed.insert(.circle) }
        if b0 & 0x80 != 0 { pressed.insert(.triangle) }

        if b1 & 0x01 != 0 { pressed.insert(.l1) }
        if b1 & 0x02 != 0 { pressed.insert(.r1) }
        if b1 & 0x04 != 0 { pressed.insert(.l2) }
        if b1 & 0x08 != 0 { pressed.insert(.r2) }
        if b1 & 0x10 != 0 { pressed.insert(.create) }
        if b1 & 0x20 != 0 { pressed.insert(.options) }
        if b1 & 0x40 != 0 { pressed.insert(.l3) }
        if b1 & 0x80 != 0 { pressed.insert(.r3) }

        if b2 & 0x01 != 0 { pressed.insert(.ps) }
        if b2 & 0x02 != 0 { pressed.insert(.touchpad) }
        if b2 & 0x04 != 0 { pressed.insert(.mute) }
    }

    /// Raw 0-255 to -1...1. Centre is 127.5 rather than 128, so a resting stick reads as
    /// a small symmetric offset rather than a permanent drift in one direction.
    private static func axis(_ raw: UInt8) -> Double {
        (Double(raw) - 127.5) / 127.5
    }

    private static func int16(_ bytes: [UInt8], at index: Int) -> Int16 {
        Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
    }

    public var accelMagnitude: Double {
        (accelX * accelX + accelY * accelY + accelZ * accelZ).squareRoot()
    }
}

// MARK: - Device

public final class DualSenseDevice {
    public let device: IOHIDDevice
    public let productName: String
    public let transport: String
    public let bufferSize: Int
    public let buffer: UnsafeMutablePointer<UInt8>
    public var lastState = ButtonState()
    public var lastReportAt = Date()
    public var touchDown = false
    public var touchStart: (x: Int, y: Int, at: Date)?
    /// Whether this handle currently holds an exclusive seize. Tracked on the device so
    /// the seize can be dropped from any path — including the controller vanishing
    /// mid-capture, where the normal release never runs.
    public var isSeized = false
    private var outputSequence: UInt8 = 0

    public var isBluetooth: Bool { transport.lowercased().contains("bluetooth") }

    public init(device: IOHIDDevice) {
        self.device = device
        self.productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "DualSense"
        self.transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "Unknown"
        let maxSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 78
        self.bufferSize = max(maxSize, 78)
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: self.bufferSize)
        self.buffer.initialize(repeating: 0, count: self.bufferSize)
    }

    deinit {
        buffer.deinitialize(count: bufferSize)
        buffer.deallocate()
    }

    /// Bluetooth output report (78 bytes): [0]=0x31, [1]=sequence<<4, [2]=tag 0x10,
    /// [3..49]=common payload, [50..73]=reserved, [74..77]=CRC32 over 0xA2 + bytes 0..73.
    /// USB (63 bytes): [0]=0x02, [1..47]=common. The report ID must be in the buffer as
    /// well as the reportID argument — confirmed by hardware test, a buffer without it is
    /// accepted by IOKit and then ignored by the controller.
    /// valid_flag0 bits 0 and 1 are what make the two motor bytes mean anything. They
    /// used to be asserted only when the strength was above zero, which made every stop
    /// report a report that changed nothing: the controller read valid_flag0 as "the
    /// motor bytes are not for you", ignored the zeroes, and kept buzzing until its own
    /// watchdog gave up seconds later. That is the stuck rumble. The flag now goes out
    /// on every rumble report, including the one that says stop.
    public func rumble(_ strength: UInt8) {
        var common = [UInt8](repeating: 0, count: 47)
        common[0] = 0x03                        // HAPTICS_SELECT | COMPATIBLE_VIBRATION
        common[2] = strength                    // motor_right
        common[3] = strength                    // motor_left
        send(common: common)
    }

    /// What an adaptive trigger should do. Resistance begins at `from` (0 = the top of the
    /// travel, 9 = the bottom) at `strength` 1-8. Off leaves the trigger free.
    public enum TriggerEffect: Equatable {
        case off
        case resistance(from: Int, strength: Int)
    }

    /// Sets both adaptive triggers.
    ///
    /// The encoding is the "feedback" effect the PS5's own games use, as documented by
    /// the open-source trigger-effect generators and by what Steam Input sends: a mode
    /// byte, then a ten-bit mask of active zones and a three-bits-per-zone force table.
    /// Right trigger at bytes 10-20 of the payload, left at 21-31, each enabled by its own
    /// bit in valid_flag0. Nothing else in the report is marked valid, so the motors and
    /// lights are left exactly as they are.
    public func setTriggers(left: TriggerEffect, right: TriggerEffect) {
        var common = [UInt8](repeating: 0, count: 47)
        common[0] = 0x04 | 0x08     // right trigger valid | left trigger valid
        Self.write(effect: right, into: &common, at: 10)
        Self.write(effect: left, into: &common, at: 21)
        send(common: common)
    }

    private static func write(effect: TriggerEffect, into common: inout [UInt8], at offset: Int) {
        switch effect {
        case .off:
            common[offset] = 0x05           // the reset-to-free mode Steam uses, not "no change"
        case .resistance(let from, let strength):
            let start = min(max(from, 0), 9)
            let force = UInt32(min(max(strength, 1), 8) - 1) & 0x07
            var activeZones: UInt32 = 0
            var forceZones: UInt32 = 0
            for zone in start...9 {
                activeZones |= 1 << UInt32(zone)
                forceZones |= force << (3 * UInt32(zone))
            }
            common[offset] = 0x21
            common[offset + 1] = UInt8(activeZones & 0xFF)
            common[offset + 2] = UInt8((activeZones >> 8) & 0xFF)
            common[offset + 3] = UInt8(forceZones & 0xFF)
            common[offset + 4] = UInt8((forceZones >> 8) & 0xFF)
            common[offset + 5] = UInt8((forceZones >> 16) & 0xFF)
            common[offset + 6] = UInt8((forceZones >> 24) & 0xFF)
        }
    }

    /// The lights. None of this is for the person holding the controller in this app's
    /// case — it is for anyone else in the room, and for the day someone sighted uses it.
    /// Cheap, and it makes the thing look alive. The mute button's own LED is the useful
    /// one: it is the capture button, so lit means captured.
    ///
    /// Layout from the Linux hid-playstation driver, which is authoritative for these
    /// bytes: mute LED at 8, player LEDs bitmask at 43, lightbar RGB at 44-46, each
    /// enabled by its bit in valid_flag1.
    public func setLights(muteLED: Bool, lightbar: (red: UInt8, green: UInt8, blue: UInt8), playerLEDs: UInt8) {
        var common = [UInt8](repeating: 0, count: 47)
        common[1] = 0x01 | 0x04 | 0x10      // mute LED | lightbar | player indicators valid
        common[8] = muteLED ? 0x01 : 0x00
        common[43] = playerLEDs & 0x1F
        common[44] = lightbar.red
        common[45] = lightbar.green
        common[46] = lightbar.blue
        send(common: common)
    }

    /// RELEASE_LEDS: the controller goes back to driving its own lightbar and player
    /// indicators, as it does for any app that never touched them.
    public func releaseLights() {
        var common = [UInt8](repeating: 0, count: 47)
        common[1] = 0x08
        common[8] = 0
        send(common: common)
    }

    /// Points the controller's audio at its own speaker and takes the actuators out of
    /// classic-rumble mode.
    ///
    /// Everything here is reconstructed from the open-source drivers for this controller,
    /// not from Sony, and the one field I am least sure of is the output path in byte 7 —
    /// hence `pathFlags` being a parameter rather than a constant, and the sweep button in
    /// the Status tab. What I am confident of: byte 4 is headphone volume, byte 5 speaker
    /// volume, and the top nibble of valid_flag0 is what makes those bytes take effect.
    ///
    /// Critically this sends valid_flag0 WITHOUT bits 0 and 1. Asserting COMPATIBLE_VIBRATION
    /// or HAPTICS_SELECT switches the voice coils to emulating the old rumble motors, and
    /// once switched they stop responding to the audio channels.
    public func configureAudio(pathFlags: UInt8, speakerVolume: UInt8 = 0x7F) {
        var common = [UInt8](repeating: 0, count: 47)
        common[0] = 0xF0        // headphone vol | speaker vol | mic vol | audio control valid
        common[1] = 0x00
        common[2] = 0           // motors explicitly off
        common[3] = 0
        common[4] = 0x7F        // headphone volume
        common[5] = speakerVolume
        common[6] = 0x40        // microphone volume
        common[7] = pathFlags   // output path select
        send(common: common)
        log("Sent DS5 audio config: pathFlags=0x\(String(pathFlags, radix: 16)) speakerVolume=\(speakerVolume)")
    }

    private func send(common: [UInt8]) {
        var report: [UInt8]
        let reportID: CFIndex

        if isBluetooth {
            reportID = 0x31
            report = [UInt8](repeating: 0, count: 78)
            report[0] = 0x31
            report[1] = UInt8((outputSequence & 0x0F) << 4)
            report[2] = 0x10
            for index in 0..<47 { report[3 + index] = common[index] }
            var crcInput: [UInt8] = [0xA2]
            crcInput.append(contentsOf: report[0..<74])
            let crc = Self.crc32(crcInput)
            report[74] = UInt8(crc & 0xFF)
            report[75] = UInt8((crc >> 8) & 0xFF)
            report[76] = UInt8((crc >> 16) & 0xFF)
            report[77] = UInt8((crc >> 24) & 0xFF)
        } else {
            reportID = 0x02
            report = [UInt8](repeating: 0, count: 63)
            report[0] = 0x02
            for index in 0..<47 { report[1 + index] = common[index] }
        }
        outputSequence = (outputSequence &+ 1) & 0x0F

        let result = report.withUnsafeBufferPointer { pointer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, pointer.baseAddress!, report.count)
        }
        if result != kIOReturnSuccess {
            log("Output report rejected: 0x\(String(format: "%08X", result))")
        }
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - C callbacks

private func onInputReport(context: UnsafeMutableRawPointer?, result: IOReturn,
                           sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                           reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                           reportLength: CFIndex) {
    guard let context = context, let sender = sender else { return }
    let reader = Unmanaged<DualSenseReader>.fromOpaque(context).takeUnretainedValue()
    let device = unsafeBitCast(sender, to: IOHIDDevice.self)
    reader.handleReport(device: device, reportID: reportID,
                        bytes: Array(UnsafeBufferPointer(start: report, count: Int(reportLength))))
}

private func onDeviceMatched(context: UnsafeMutableRawPointer?, result: IOReturn,
                             sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    Unmanaged<DualSenseReader>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
}

private func onDeviceRemoved(context: UnsafeMutableRawPointer?, result: IOReturn,
                             sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context = context else { return }
    Unmanaged<DualSenseReader>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
}

// MARK: - Reader

/// Passive, non-exclusive HID reader. Never seizes the device, so Steam, Shadow PC
/// and Remote Play keep working exactly as before.
public final class DualSenseReader: ObservableObject {
    /// The class became public with the Keel split; without this the implicit
    /// initializer stays internal and the apps cannot construct a reader.
    public init() {}

    @Published public private(set) var status = "Starting."
    @Published private(set) var isConnected = false
    @Published private(set) var isCaptured = false

    /// The most recent decoded report. Read rather than subscribed to, because the
    /// controller sends around 250 reports a second and nothing on screen needs updating
    /// that often — mouse mode polls this at its own frame rate instead.
    public private(set) var latest = ButtonState()

    /// Called on the main thread for every button that transitions to pressed.
    public var onPress: ((DSButton) -> Void)?
    /// Fired when a button comes back up. Only the modifier uses it, and only so that a tap
    /// and a hold can mean different things.
    public var onRelease: ((DSButton) -> Void)?
    /// Called when the controller goes away, so callers can drop any state that assumed it.
    public var onDisconnect: (() -> Void)?
    /// Called when a controller appears. The controller's USB audio device appears with
    /// it, so this is when the sound route has to be re-checked.
    public var onConnect: (() -> Void)?
    /// A sharp shake. The one way out of every mode that needs no button to be found.
    public var onShake: (() -> Void)?
    /// Battery has crossed down through the warning level while not on charge.
    public var onLowBattery: ((Int) -> Void)?

    private var shakePeaks: [Date] = []
    private var lastShakeAt = Date.distantPast
    private var lastBatteryWarnedAt = 101
    private var lastLoggedBatteryLevel = -1
    /// Peaks above this many g, this many times inside the window, is a shake. A lift off
    /// the desk is one peak; a deliberate shake is several. The 120ms floor between peaks
    /// stops a single jolt from counting more than once.
    private let shakeThreshold = 2.3
    private let shakeCount = 3
    private let shakeWindow: TimeInterval = 1.0

    public var battery: (percent: Int, charging: Bool, known: Bool) {
        (latest.batteryPercent, latest.charging, latest.batteryKnown)
    }

    private var manager: IOHIDManager?
    private var devices: [UnsafeRawPointer: DualSenseDevice] = [:]
    private var watchdog: Timer?

    public var activeDevice: DualSenseDevice? { devices.values.first }

    public func start() {
        guard manager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        manager = mgr

        let matching: [[String: Any]] = [[kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0CE6],
                                         [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: 0x0DF2]]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, onDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, onDeviceRemoved, context)
        // commonModes, not defaultMode: the main run loop leaves the default mode whenever
        // AppKit tracks a menu, a modal panel or a window resize, and in the default mode
        // no reports are delivered at all during those. The device is still seized, so
        // nothing else receives them either — the controller simply goes dead, including
        // the modifier that is meant to always hand it back.
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(mgr, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnSuccess {
            status = "Waiting for a controller."
            log("Reader started, non-exclusive.")
        } else {
            status = "Could not open the controller: " + String(format: "0x%08X", UInt32(bitPattern: openResult))
            log("IOHIDManagerOpen failed: \(openResult)")
        }

        // Re-arms the stream if a device is nominally present but has gone silent. The
        // previous one is invalidated first: resetAccess rebuilds through here, and each
        // rebuild used to add another watchdog on top of the last.
        watchdog?.invalidate()
        watchdog = Timer.common(5.0, repeats: true) { [weak self] _ in
            self?.checkLiveness()
        }
    }

    private func checkLiveness() {
        guard let device = activeDevice else { return }
        if Date().timeIntervalSince(device.lastReportAt) > 10 {
            log("Stream silent for over 10s — re-registering input callback.")
            IOHIDDeviceRegisterInputReportCallback(device.device, device.buffer, device.bufferSize,
                                                   onInputReport, Unmanaged.passUnretained(self).toOpaque())
            device.lastReportAt = Date()
        }
    }

    public func deviceAdded(_ device: IOHIDDevice) {
        let key = UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())
        guard devices[key] == nil else { return }

        let wrapped = DualSenseDevice(device: device)
        devices[key] = wrapped
        _ = IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        IOHIDDeviceRegisterInputReportCallback(device, wrapped.buffer, wrapped.bufferSize,
                                               onInputReport, Unmanaged.passUnretained(self).toOpaque())
        // The one stop that can be sent after a crash. Nothing catches SIGKILL, so a
        // process that dies mid-pulse leaves the motors running with nobody left to stop
        // them; the next time the device is seen — a relaunch, a reconnect, a reset — this
        // is the report that silences it.
        wrapped.rumble(0)
        isConnected = true
        status = "\(wrapped.productName) connected over \(wrapped.transport)."
        log("Connected: \(wrapped.productName) over \(wrapped.transport)")
        // The audio device is published a moment after the HID one, so give it a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.onConnect?() }
    }

    // MARK: Capture

    /// Exclusive capture. While captured, IOKit stops delivering this device's reports to
    /// other clients, so Shadow PC, Steam and Remote Play stop seeing button presses
    /// entirely — the point being that a chord's second button no longer leaks into
    /// whatever is in front. Releasing hands the controller straight back.
    ///
    /// Whether a seize actually blocks every other client on macOS 27 is not something I
    /// could confirm from documentation, so the result is logged either way and the app
    /// falls back to non-exclusive if the seize is refused.
    @discardableResult
    public func setCaptured(_ captured: Bool) -> Bool {
        guard let wrapped = activeDevice else {
            log("CAPTURE \(captured ? "on" : "off") requested with no device attached.")
            return false
        }
        let device = wrapped.device

        fullyClose(wrapped)

        let option = captured
            ? IOHIDOptionsType(kIOHIDOptionsTypeSeizeDevice)
            : IOHIDOptionsType(kIOHIDOptionsTypeNone)
        let result = IOHIDDeviceOpen(device, option)

        if result != kIOReturnSuccess && captured {
            log("SEIZE FAILED (\(String(format: "0x%08X", UInt32(bitPattern: result)))) — reopening non-exclusive.")
            _ = IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            wrapped.isSeized = false
            reregister(wrapped)
            isCaptured = false
            return false
        }

        wrapped.isSeized = (captured && result == kIOReturnSuccess)
        reregister(wrapped)
        isCaptured = captured
        log("CAPTURE \(captured ? "ON — controller decoupled from other apps" : "OFF — controller handed back") result=\(String(format: "0x%08X", UInt32(bitPattern: result)))")
        return true
    }

    private func reregister(_ wrapped: DualSenseDevice) {
        IOHIDDeviceRegisterInputReportCallback(wrapped.device, wrapped.buffer, wrapped.bufferSize,
                                               onInputReport, Unmanaged.passUnretained(self).toOpaque())
        wrapped.lastReportAt = Date()
    }

    /// Always hand the controller back, whatever the app was doing.
    public func setTriggers(left: DualSenseDevice.TriggerEffect, right: DualSenseDevice.TriggerEffect) {
        for wrapped in devices.values { wrapped.setTriggers(left: left, right: right) }
    }

    public func setLights(muteLED: Bool, lightbar: (red: UInt8, green: UInt8, blue: UInt8), playerLEDs: UInt8) {
        for wrapped in devices.values {
            wrapped.setLights(muteLED: muteLED, lightbar: lightbar, playerLEDs: playerLEDs)
        }
    }

    /// Pushes the audio configuration to whichever controller is attached.
    public func configureAudio(pathFlags: UInt8, speakerVolume: UInt8 = 0x7F) {
        for wrapped in devices.values {
            wrapped.configureAudio(pathFlags: pathFlags, speakerVolume: speakerVolume)
        }
    }

    /// Motors do not stop when the handle closes — only a power cycle or another client
    /// writing to the device stops them. So this goes out before any close.
    public func silenceRumble() {
        for wrapped in devices.values { wrapped.rumble(0) }
    }

    /// Hands the lights back to the controller's own defaults and frees the triggers.
    /// Stiff triggers and an amber lightbar left behind after quit would be this app's
    /// version of a stuck mode.
    public func resetPresence() {
        for wrapped in devices.values {
            wrapped.setTriggers(left: .off, right: .off)
            wrapped.releaseLights()
        }
    }

    public func releaseEverything() {
        silenceRumble()
        resetPresence()
        if isCaptured { setCaptured(false) }
        for state in devices.values { fullyClose(state) }
        if let manager = manager {
            IOHIDManagerClose(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        }
        log("Released every controller handle.")
    }

    /// Tears the whole HID connection down and builds it again.
    ///
    /// Seizing a device evicts the other apps reading it, and dropping the seize does not
    /// bring them back by itself — they only re-attach when the device is republished.
    /// This is the closest thing to unplugging and replugging that an app can do, and it
    /// is the remedy when something else has lost the controller and not found it again.
    public func resetAccess() {
        log("Resetting controller access.")
        // Before the close, not after: the motors do not stop when the handle does, and a
        // pulse in flight when the device goes away runs until the controller's own
        // watchdog gives up. `releaseEverything` has always done this and `resetAccess`
        // never did, which is the second half of the buzzing-after-a-launch fault — the
        // handover resets access roughly twenty milliseconds after the hand-back pulse
        // starts, so there was a stop scheduled for a device that no longer existed.
        silenceRumble()
        for state in devices.values { fullyClose(state) }
        devices.removeAll()
        isCaptured = false
        isConnected = false
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        }
        manager = nil
        status = "Resetting controller access."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.start()
        }
    }

    /// Drops any seize and closes the handle. Safe to call more than once.
    private func fullyClose(_ state: DualSenseDevice) {
        if state.isSeized {
            IOHIDDeviceClose(state.device, IOHIDOptionsType(kIOHIDOptionsTypeSeizeDevice))
            state.isSeized = false
            log("Released seize on \(state.productName).")
        }
        IOHIDDeviceClose(state.device, IOHIDOptionsType(kIOHIDOptionsTypeNone))
    }

    public func deviceRemoved(_ device: IOHIDDevice) {
        let key = UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())
        guard let state = devices.removeValue(forKey: key) else { return }
        // Without this, a controller that drops out while captured leaves a seized handle
        // that nothing can reach afterwards — the state it belonged to is already gone.
        fullyClose(state)
        isConnected = !devices.isEmpty
        if devices.isEmpty { isCaptured = false }
        status = devices.isEmpty ? "Controller disconnected. Waiting for it to come back." : status
        log("Disconnected. Waiting for reconnect.")
        onDisconnect?()
    }

    /// Every callout to the rest of the app goes through here, one run-loop pass later.
    ///
    /// **Nothing that can touch the HID layer may run inside a HID callback.** Input
    /// reports arrive on the main thread from `IOHIDDeviceClass::valueAvailableCallback`,
    /// which is holding that device's own lock for the duration of the call. A binding is
    /// free to close and reopen the device — capture toggles do, the handover before a
    /// launch does, "Reset controller access" does — and doing it from inside the callback
    /// destroys the object whose lock the callback is about to release. libplatform
    /// notices and kills the process outright:
    ///
    ///     BUG IN CLIENT OF LIBPLATFORM: Unlock of an os_unfair_lock not owned by current thread
    ///
    /// with `-[IOHIDDeviceClass valueAvailableCallback:]` two frames below the abort. It is
    /// not catchable, it takes the app down mid-pulse, and a dead process cannot stop the
    /// motors — so the visible symptom was a controller that buzzed for several seconds
    /// after choosing something, which reads as a rumble bug and is not one.
    ///
    /// This is the same lesson as the AVAudioEngine one already in the README: do not take
    /// the thing apart from inside its own callout. The decode stays synchronous, because
    /// it only reads bytes; every callout hops to the next pass, by which time the
    /// callback has returned and released its lock. Main-queue order is FIFO, so presses
    /// still arrive in the order they happened.
    private func emit(_ button: DSButton) {
        DispatchQueue.main.async { [weak self] in self?.onPress?(button) }
    }

    private func emitRelease(_ button: DSButton) {
        DispatchQueue.main.async { [weak self] in self?.onRelease?(button) }
    }

    public func handleReport(device: IOHIDDevice, reportID: UInt32, bytes: [UInt8]) {
        let key = UnsafeRawPointer(Unmanaged.passUnretained(device).toOpaque())
        guard let wrapped = devices[key] else { return }
        wrapped.lastReportAt = Date()

        guard let state = ButtonState(reportID: reportID, bytes: bytes) else { return }
        // Fixed order, not the set's hash order: two buttons that change in the same
        // report must dispatch predictably, because each handler can change what the next
        // one sees — the modifier and a bound button together could toggle capture before
        // or after the binding ran.
        let newlyPressed = state.pressed.subtracting(wrapped.lastState.pressed)
        // Computed before the state is replaced, obviously, and needed at all because a
        // button that can be tapped or held is two different controls and only the release
        // says which one it was.
        let newlyReleased = wrapped.lastState.pressed.subtracting(state.pressed)
        wrapped.lastState = state
        latest = state
        detectShake(state)
        watchBattery(state)
        for button in DSButton.allCases where newlyPressed.contains(button) { emit(button) }
        for button in DSButton.allCases where newlyReleased.contains(button) { emitRelease(button) }

        handleTouch(wrapped, reportID: reportID, bytes: bytes)
    }

    private func detectShake(_ state: ButtonState) {
        guard state.accelMagnitude > shakeThreshold else { return }
        let now = Date()
        if let last = shakePeaks.last, now.timeIntervalSince(last) < 0.12 { return }
        shakePeaks.append(now)
        shakePeaks.removeAll { now.timeIntervalSince($0) > shakeWindow }
        guard shakePeaks.count >= shakeCount, now.timeIntervalSince(lastShakeAt) > 2 else { return }
        lastShakeAt = now
        shakePeaks.removeAll()
        log("Shake detected (\(String(format: "%.1f", state.accelMagnitude))g).")
        // Escape drops the seize, so it is a HID teardown and hops out of the callback
        // for exactly the same reason a press does.
        DispatchQueue.main.async { [weak self] in self?.onShake?() }
    }

    private func watchBattery(_ state: ButtonState) {
        guard state.batteryKnown else { return }

        // Log the level whenever it changes. The status byte's offset was wrong once
        // already and nothing said so; a line in the log makes it checkable by reading
        // rather than by waiting for a warning that may never come.
        if state.batteryPercent != lastLoggedBatteryLevel {
            lastLoggedBatteryLevel = state.batteryPercent
            log("Battery \(state.batteryPercent)%\(state.charging ? ", charging" : "").")
        }

        guard !state.charging else { lastBatteryWarnedAt = 101; return }
        let level = state.batteryPercent
        // Warn once at each of 20 and 10, not continuously, and re-arm after a charge.
        for threshold in [20, 10] where level <= threshold && lastBatteryWarnedAt > threshold {
            lastBatteryWarnedAt = threshold
            log("Battery low: \(level)%.")
            let warned = level
            DispatchQueue.main.async { [weak self] in self?.onLowBattery?(warned) }
            break
        }
    }

    /// The touchpad surface is separate from the touchpad click, and macOS exposes none
    /// of it — the finger data is only in the raw report. Each touch point is four bytes:
    /// a contact byte whose top bit is SET when NOT touching, then a 12-bit x and 12-bit y
    /// packed across the remaining three. x runs 0-1919 left to right, y 0-1079 top to bottom.
    private func handleTouch(_ wrapped: DualSenseDevice, reportID: UInt32, bytes: [UInt8]) {
        let base: Int
        switch reportID {
        case 0x31: base = 34
        case 0x01: base = 33
        default: return
        }
        guard bytes.count > base + 3 else { return }

        let touching = (bytes[base] & 0x80) == 0
        let x = Int(bytes[base + 1]) | (Int(bytes[base + 2] & 0x0F) << 8)
        let y = Int((bytes[base + 2] & 0xF0) >> 4) | (Int(bytes[base + 3]) << 4)

        if touching && !wrapped.touchDown {
            wrapped.touchDown = true
            wrapped.touchStart = (x: x, y: y, at: Date())
            return
        }

        guard !touching, wrapped.touchDown, let start = wrapped.touchStart else {
            if !touching { wrapped.touchDown = false }
            return
        }

        wrapped.touchDown = false
        wrapped.touchStart = nil

        let dx = x - start.x
        let dy = y - start.y
        let elapsed = Date().timeIntervalSince(start.at)
        // 1920 wide, 1080 tall: a fifth of the pad in one direction reads as a swipe.
        let threshold = 380

        if abs(dx) > threshold && abs(dx) >= abs(dy) {
            emit(dx > 0 ? .swipeRight : .swipeLeft)
        } else if abs(dy) > threshold {
            emit(dy > 0 ? .swipeDown : .swipeUp)
        } else if elapsed < 0.4 && abs(dx) < 120 && abs(dy) < 120 {
            emit(.touchTap)
        }
    }
}
