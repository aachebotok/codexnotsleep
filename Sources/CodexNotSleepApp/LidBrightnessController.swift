import AppKit
import CoreFoundation
import CoreGraphics
import Darwin
import IOKit
import IOKit.graphics
import IOKit.hid

@MainActor
protocol LidAngleProviding: AnyObject {
  func currentAngle() -> Double?
}

@MainActor
final class IOKitLidAngleSensor: LidAngleProviding {
  static let vendorID = 0x05AC
  static let productID = 0x8104
  static let usagePage = 0x0020
  static let usage = 0x008A
  // The AppleSPUHIDDevice exposes the lid angle as an input element with
  // usage 0x047F inside the 0x20/0x8A sensor collection.
  static let angleUsage = 0x047F

  private var manager: IOHIDManager?
  private var device: IOHIDDevice?
  private var angleElement: IOHIDElement?

  func currentAngle() -> Double? {
    guard ensureDevice() else { return nil }
    guard let device, let angleElement else {
      disconnect()
      return nil
    }

    guard let rawAngle = Self.readAngle(device: device, element: angleElement) else {
      disconnect()
      return nil
    }

    // Apple reports `1` for the docked/fully closed position on this sensor.
    return rawAngle <= 1
      ? 0
      : min(Double(rawAngle), LidBrightnessCurve.sensorMaximumAngle)
  }

  private func ensureDevice() -> Bool {
    if device != nil { return true }
    return connect()
  }

  private func connect() -> Bool {
    disconnect()

    let manager = IOHIDManagerCreate(
      kCFAllocatorDefault,
      IOOptionBits(kIOHIDOptionsTypeNone)
    )

    let matching: [String: Any] = [
      kIOHIDVendorIDKey as String: Self.vendorID,
      kIOHIDProductIDKey as String: Self.productID,
      kIOHIDPrimaryUsagePageKey as String: Self.usagePage,
      kIOHIDPrimaryUsageKey as String: Self.usage,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

    guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    else {
      return false
    }
    self.manager = manager

    guard let devices = IOHIDManagerCopyDevices(manager) else {
      disconnect()
      return false
    }

    var values = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(devices))
    CFSetGetValues(devices, &values)

    for value in values {
      guard let value else { continue }
      let device = Unmanaged<IOHIDDevice>.fromOpaque(value).takeUnretainedValue()
      guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
      else { continue }

      self.device = device
      guard let angleElement = Self.findAngleElement(on: device),
            Self.readAngle(device: device, element: angleElement) != nil
      else {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
        continue
      }

      self.angleElement = angleElement
      return true
    }

    disconnect()
    return false
  }

  private static func findAngleElement(on device: IOHIDDevice) -> IOHIDElement? {
    guard let elements = IOHIDDeviceCopyMatchingElements(
      device,
      nil,
      IOOptionBits(kIOHIDOptionsTypeNone)
    ) else {
      return nil
    }

    let count = CFArrayGetCount(elements)
    for index in 0..<count {
      guard let rawElement = CFArrayGetValueAtIndex(elements, index) else { continue }
      let element = Unmanaged<IOHIDElement>.fromOpaque(rawElement).takeUnretainedValue()
      guard IOHIDElementGetUsagePage(element) == Self.usagePage,
            IOHIDElementGetUsage(element) == Self.angleUsage,
            IOHIDElementGetType(element) == kIOHIDElementTypeInput_Axis ||
              IOHIDElementGetType(element) == kIOHIDElementTypeInput_Misc
      else { continue }
      return element
    }
    return nil
  }

  private static func readAngle(
    device: IOHIDDevice,
    element: IOHIDElement
  ) -> Int64? {
    let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
    defer { valuePointer.deallocate() }

    let result = IOHIDDeviceGetValue(device, element, valuePointer)
    guard result == kIOReturnSuccess else { return nil }
    return Int64(IOHIDValueGetIntegerValue(valuePointer.pointee.takeUnretainedValue()))
  }

  private func disconnect() {
    angleElement = nil
    if let device {
      IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
      self.device = nil
    }
    if let manager {
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
      self.manager = nil
    }
  }
}

enum LidBrightnessCurve {
  static let minimumBrightness = 0.01
  static let closedAngle = 1.0
  static let restorationAngle = 60.0
  static let sensorMaximumAngle = 180.0
  static let defaultTransitionDuration: TimeInterval = 0.75

  static func openFraction(
    for angle: Double,
    openAngle: Double = Self.restorationAngle
  ) -> Double {
    guard angle.isFinite else { return 1 }
    let referenceAngle = min(max(openAngle, closedAngle), Self.sensorMaximumAngle)
    let span = referenceAngle - closedAngle
    guard span > 0 else { return 0 }
    return min(max((angle - closedAngle) / span, 0), 1)
  }

  static func targetBrightness(
    original: Double,
    angle: Double,
    openAngle: Double = Self.restorationAngle
  ) -> Double {
    let original = min(max(original, 0), 1)
    let closedBrightness = min(original, minimumBrightness)
    return closedBrightness
      + (original - closedBrightness)
        * openFraction(for: angle, openAngle: openAngle)
  }

  static func smoothProgress(_ progress: Double) -> Double {
    let progress = min(max(progress, 0), 1)
    return progress * progress * (3 - 2 * progress)
  }
}

struct ManagedDisplayBrightness: Equatable {
  let id: UInt32
  let brightness: Double
}

@MainActor
protocol DisplayBrightnessProviding: AnyObject {
  func currentBuiltInDisplay() -> ManagedDisplayBrightness?

  @discardableResult
  func setBrightness(_ brightness: Double, for displayID: UInt32) -> Bool
}

@MainActor
final class SystemDisplayBrightnessProvider: DisplayBrightnessProviding {
  private typealias GetBrightnessFunction = @convention(c) (
    CGDirectDisplayID,
    UnsafeMutablePointer<Float>
  ) -> Int32
  private typealias SetBrightnessFunction = @convention(c) (
    CGDirectDisplayID,
    Float
  ) -> Int32

  private let displayServicesHandle: UnsafeMutableRawPointer?
  private let getDisplayServicesBrightness: GetBrightnessFunction?
  private let setDisplayServicesBrightness: SetBrightnessFunction?

  init() {
    let handle = dlopen(
      "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
      RTLD_LAZY
    )
    displayServicesHandle = handle
    if let handle {
      getDisplayServicesBrightness = Self.function(
        named: "DisplayServicesGetBrightness",
        from: handle
      )
      setDisplayServicesBrightness = Self.function(
        named: "DisplayServicesSetBrightness",
        from: handle
      )
    } else {
      getDisplayServicesBrightness = nil
      setDisplayServicesBrightness = nil
    }
  }

  func currentBuiltInDisplay() -> ManagedDisplayBrightness? {
    guard let displayID = builtInDisplayID() else { return nil }
    guard let brightness = brightness(for: displayID) else { return nil }
    return ManagedDisplayBrightness(id: displayID, brightness: brightness)
  }

  @discardableResult
  func setBrightness(_ brightness: Double, for displayID: UInt32) -> Bool {
    let value = Float(min(max(brightness, 0), 1))
    let displayID = CGDirectDisplayID(displayID)

    if let setDisplayServicesBrightness,
       setDisplayServicesBrightness(displayID, value) == kIOReturnSuccess
    {
      return true
    }

    return withFirstDisplayService { service in
      IODisplaySetFloatParameter(
        service,
        0,
        kIODisplayBrightnessKey as CFString,
        value
      ) == kIOReturnSuccess
    } ?? false
  }

  private func builtInDisplayID() -> UInt32? {
    for screen in NSScreen.screens {
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else { continue }
      let displayID = CGDirectDisplayID(number.uint32Value)
      if CGDisplayIsBuiltin(displayID) == 1 {
        return UInt32(displayID)
      }
    }
    return nil
  }

  private func brightness(for displayID: UInt32) -> Double? {
    if let getDisplayServicesBrightness {
      var value: Float = 0
      if getDisplayServicesBrightness(CGDirectDisplayID(displayID), &value) == kIOReturnSuccess {
        return min(max(Double(value), 0), 1)
      }
    }

    return withFirstDisplayService { service in
      var value: Float = 0
      guard
        IODisplayGetFloatParameter(
          service,
          0,
          kIODisplayBrightnessKey as CFString,
          &value
        ) == kIOReturnSuccess
      else { return nil }
      return min(max(Double(value), 0), 1)
    }
  }

  private func withFirstDisplayService<T>(_ body: (io_service_t) -> T?) -> T? {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IODisplayConnect"),
        &iterator
      ) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }

    let service = IOIteratorNext(iterator)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return body(service)
  }

  private static func function<T>(
    named name: String,
    from handle: UnsafeMutableRawPointer
  ) -> T? {
    guard let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: T.self)
  }
}

@MainActor
protocol LidBrightnessControlling: AnyObject {
  func setCodexWorking(_ isWorking: Bool)
  func reset()
}

@MainActor
final class NoOpLidBrightnessController: LidBrightnessControlling {
  func setCodexWorking(_ isWorking: Bool) {}
  func reset() {}
}

@MainActor
final class LidBrightnessController: LidBrightnessControlling {
  private struct DisplayState {
    let original: Double
    let referenceOpenAngle: Double
    var current: Double
    var target: Double
    var transitionFrom: Double
    var transitionStartedAt: Date?
  }

  private static let frameInterval: TimeInterval = 1.0 / 30.0
  private static let sensorInterval: TimeInterval = 1.0 / 10.0
  private static let transitionDuration = LidBrightnessCurve.defaultTransitionDuration

  private let angleSensor: any LidAngleProviding
  private let displayProvider: any DisplayBrightnessProviding
  private var displayStates: [UInt32: DisplayState] = [:]
  private var timer: Timer?
  private var isCodexWorking = false
  private var lastSensorReadAt = Date.distantPast
  private var currentAngle: Double?

  init(
    angleSensor: any LidAngleProviding = IOKitLidAngleSensor(),
    displayProvider: any DisplayBrightnessProviding = SystemDisplayBrightnessProvider()
  ) {
    self.angleSensor = angleSensor
    self.displayProvider = displayProvider
  }

  func setCodexWorking(_ isWorking: Bool) {
    if isWorking {
      guard !isCodexWorking else { return }
      isCodexWorking = true
      if displayStates.isEmpty {
        beginManagingBrightness()
      } else {
        lastSensorReadAt = Date.now
        if let angle = angleSensor.currentAngle() {
          currentAngle = angle
          updateTargets(for: angle, at: Date.now)
          ensureTimer()
        } else {
          isCodexWorking = false
          restoreBrightness()
        }
      }
      return
    }

    guard isCodexWorking || !displayStates.isEmpty else { return }
    isCodexWorking = false
    restoreBrightness()
  }

  func reset() {
    isCodexWorking = false
    for (id, state) in displayStates {
      _ = displayProvider.setBrightness(state.original, for: id)
    }
    displayStates.removeAll()
    timer?.invalidate()
    timer = nil
  }

  private func beginManagingBrightness() {
    guard let angle = angleSensor.currentAngle(),
          let display = displayProvider.currentBuiltInDisplay()
    else {
      isCodexWorking = false
      return
    }

    currentAngle = angle
    lastSensorReadAt = Date.now
    let referenceOpenAngle = referenceOpenAngle(for: angle)
    let target = LidBrightnessCurve.targetBrightness(
      original: display.brightness,
      angle: angle,
      openAngle: referenceOpenAngle
    )
    displayStates[display.id] = DisplayState(
      original: display.brightness,
      referenceOpenAngle: referenceOpenAngle,
      current: display.brightness,
      target: target,
      transitionFrom: display.brightness,
      transitionStartedAt: target == display.brightness ? nil : Date.now
    )
    ensureTimer()
  }

  private func restoreBrightness() {
    let now = Date.now
    for id in displayStates.keys {
      guard var state = displayStates[id] else { continue }
      guard abs(state.target - state.original) > 0.0001 || state.transitionStartedAt != nil
      else { continue }
      state.transitionFrom = state.current
      state.target = state.original
      state.transitionStartedAt = now
      displayStates[id] = state
    }

    if displayStates.isEmpty {
      timer?.invalidate()
      timer = nil
    } else {
      ensureTimer()
    }
  }

  private func ensureTimer() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.tick()
      }
    }
    timer.tolerance = 0.01
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    let now = Date.now
    if isCodexWorking, now.timeIntervalSince(lastSensorReadAt) >= Self.sensorInterval {
      lastSensorReadAt = now
      if let angle = angleSensor.currentAngle() {
        currentAngle = angle
        updateTargets(for: angle, at: now)
      } else {
        // A lost sensor must never leave a dimmed screen behind.
        currentAngle = nil
        isCodexWorking = false
        restoreBrightness()
      }
    }

    var finishedIDs: [UInt32] = []
    for (id, var state) in displayStates {
      guard let transitionStartedAt = state.transitionStartedAt else {
        if !isCodexWorking, abs(state.current - state.original) <= 0.0001 {
          finishedIDs.append(id)
        }
        continue
      }
      let elapsed = now.timeIntervalSince(transitionStartedAt)
      let progress = min(max(elapsed / Self.transitionDuration, 0), 1)
      let easedProgress = LidBrightnessCurve.smoothProgress(progress)
      let value = state.transitionFrom
        + (state.target - state.transitionFrom) * easedProgress
      _ = displayProvider.setBrightness(value, for: id)
      state.current = value
      if progress >= 1 {
        state.current = state.target
        state.transitionStartedAt = nil
      }
      displayStates[id] = state

      if !isCodexWorking,
         state.transitionStartedAt == nil,
         abs(state.current - state.original) <= 0.0001
      {
        finishedIDs.append(id)
      }
    }

    for id in finishedIDs {
      displayStates.removeValue(forKey: id)
    }
    if !isCodexWorking, displayStates.isEmpty {
      timer?.invalidate()
      timer = nil
    }
  }

  private func updateTargets(for angle: Double, at date: Date) {
    for id in displayStates.keys {
      guard var state = displayStates[id] else { continue }
      let target = LidBrightnessCurve.targetBrightness(
        original: state.original,
        angle: angle,
        openAngle: state.referenceOpenAngle
      )
      guard abs(target - state.target) > 0.0005 else { continue }
      state.transitionFrom = state.current
      state.target = target
      state.transitionStartedAt = date
      displayStates[id] = state
    }
  }

  private func referenceOpenAngle(for angle: Double) -> Double {
    let angle = min(
      max(angle, LidBrightnessCurve.closedAngle),
      LidBrightnessCurve.sensorMaximumAngle
    )
    // Brightness is fully restored once the lid reaches 60 degrees. If work
    // starts below that point, preserve the current angle as the endpoint.
    return angle <= LidBrightnessCurve.closedAngle
      ? LidBrightnessCurve.restorationAngle
      : min(angle, LidBrightnessCurve.restorationAngle)
  }
}
