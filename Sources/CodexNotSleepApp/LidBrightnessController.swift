import AppKit
import CoreFoundation
import CoreGraphics
import Darwin
import IOKit
import IOKit.graphics
import IOKit.hid
import ObjectiveC.runtime

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
  static let restorationAngle = 45.0
  static let sensorMaximumAngle = 180.0

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

  static func targetKeyboardBrightness(
    original: Double,
    angle: Double,
    openAngle: Double = Self.restorationAngle
  ) -> Double {
    min(max(original, 0), 1) * openFraction(for: angle, openAngle: openAngle)
  }

  static func smoothProgress(_ progress: Double) -> Double {
    let progress = min(max(progress, 0), 1)
    return progress * progress * (3 - 2 * progress)
  }
}

struct ManagedKeyboardBacklight: Equatable {
  let id: UInt64
  let brightness: Double
}

@MainActor
protocol KeyboardBacklightProviding: AnyObject {
  func currentBuiltInKeyboard() -> ManagedKeyboardBacklight?

  @discardableResult
  func setBrightness(_ brightness: Double, for keyboardID: UInt64) -> Bool
}

@MainActor
final class NoOpKeyboardBacklightProvider: KeyboardBacklightProviding {
  func currentBuiltInKeyboard() -> ManagedKeyboardBacklight? { nil }
  func setBrightness(_ brightness: Double, for keyboardID: UInt64) -> Bool { false }
}

@MainActor
final class SystemKeyboardBacklightProvider: KeyboardBacklightProviding {
  private typealias BrightnessFunction = @convention(c) (
    AnyObject,
    Selector,
    UInt64
  ) -> Float
  private typealias IsBuiltInFunction = @convention(c) (
    AnyObject,
    Selector,
    UInt64
  ) -> Bool
  private typealias SetBrightnessFunction = @convention(c) (
    AnyObject,
    Selector,
    Float,
    Int32,
    Bool,
    UInt64
  ) -> Bool

  private static let fadeMilliseconds: Int32 = 100

  private let frameworkHandle: UnsafeMutableRawPointer?
  private let client: NSObject?

  init() {
    frameworkHandle = dlopen(
      "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
      RTLD_LAZY
    )
    if frameworkHandle != nil,
       let clientType = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
    {
      client = clientType.init()
    } else {
      client = nil
    }
  }

  func currentBuiltInKeyboard() -> ManagedKeyboardBacklight? {
    guard let client,
          let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?
            .takeRetainedValue() as? [NSNumber]
    else { return nil }

    let isBuiltInSelector = NSSelectorFromString("isKeyboardBuiltIn:")
    let brightnessSelector = NSSelectorFromString("brightnessForKeyboard:")
    guard client.responds(to: isBuiltInSelector),
          client.responds(to: brightnessSelector)
    else { return nil }

    let isBuiltIn = unsafeBitCast(
      client.method(for: isBuiltInSelector),
      to: IsBuiltInFunction.self
    )
    let readBrightness = unsafeBitCast(
      client.method(for: brightnessSelector),
      to: BrightnessFunction.self
    )

    for number in ids {
      let id = number.uint64Value
      guard isBuiltIn(client, isBuiltInSelector, id) else { continue }
      let value = Double(readBrightness(client, brightnessSelector, id))
      guard value.isFinite, value >= 0 else { continue }
      return ManagedKeyboardBacklight(id: id, brightness: min(value, 1))
    }
    return nil
  }

  @discardableResult
  func setBrightness(_ brightness: Double, for keyboardID: UInt64) -> Bool {
    guard let client else { return false }
    let selector = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
    guard client.responds(to: selector) else { return false }
    let setBrightness = unsafeBitCast(
      client.method(for: selector),
      to: SetBrightnessFunction.self
    )
    return setBrightness(
      client,
      selector,
      Float(min(max(brightness, 0), 1)),
      Self.fadeMilliseconds,
      true,
      keyboardID
    )
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
    var count: UInt32 = 0
    if CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 {
      var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
      if CGGetOnlineDisplayList(count, &displays, &count) == .success,
         let builtIn = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) == 1 })
      {
        return UInt32(builtIn)
      }
    }

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
  private struct BrightnessState {
    let original: Double
    var current: Double
    var target: Double
    var transitionFrom: Double
    var transitionStartedAt: Date?
  }

  private static let frameInterval: TimeInterval = 1.0 / 60.0
  // The lid sensor reports whole degrees. This short interpolation only fills
  // the gaps between adjacent readings; the target always comes from the angle.
  static let transitionDuration: TimeInterval = 0.15

  private let angleSensor: any LidAngleProviding
  private let displayProvider: any DisplayBrightnessProviding
  private let keyboardProvider: any KeyboardBacklightProviding
  private let schedulesTimer: Bool
  private var displayStates: [UInt32: BrightnessState] = [:]
  private var keyboardStates: [UInt64: BrightnessState] = [:]
  private var timer: Timer?
  private var isCodexWorking = false

  init(
    angleSensor: any LidAngleProviding,
    displayProvider: any DisplayBrightnessProviding,
    keyboardProvider: any KeyboardBacklightProviding = NoOpKeyboardBacklightProvider(),
    schedulesTimer: Bool = true
  ) {
    self.angleSensor = angleSensor
    self.displayProvider = displayProvider
    self.keyboardProvider = keyboardProvider
    self.schedulesTimer = schedulesTimer
  }

  convenience init() {
    self.init(
      angleSensor: IOKitLidAngleSensor(),
      displayProvider: SystemDisplayBrightnessProvider(),
      keyboardProvider: SystemKeyboardBacklightProvider()
    )
  }

  func setCodexWorking(_ isWorking: Bool) {
    if isWorking {
      if !isCodexWorking {
        isCodexWorking = true
        refreshBrightness()
      }
      ensureTimer()
      return
    }

    guard isCodexWorking || !displayStates.isEmpty || !keyboardStates.isEmpty else { return }
    isCodexWorking = false
    restoreBrightness()
  }

  func reset() {
    isCodexWorking = false
    restoreBrightness(stopping: true)
  }

  func refreshBrightness(at date: Date = .now) {
    guard isCodexWorking else { return }

    if let angle = angleSensor.currentAngle() {
      if angle >= LidBrightnessCurve.restorationAngle {
        restoreBrightness(stopping: false)
        return
      }

      if displayStates.isEmpty, let display = displayProvider.currentBuiltInDisplay() {
        displayStates[display.id] = BrightnessState(
          original: display.brightness,
          current: display.brightness,
          target: display.brightness,
          transitionFrom: display.brightness,
          transitionStartedAt: nil
        )
      }

      if keyboardStates.isEmpty, let keyboard = keyboardProvider.currentBuiltInKeyboard() {
        keyboardStates[keyboard.id] = BrightnessState(
          original: keyboard.brightness,
          current: keyboard.brightness,
          target: keyboard.brightness,
          transitionFrom: keyboard.brightness,
          transitionStartedAt: nil
        )
      }

      updateTargets(for: angle, at: date)
    }

    advanceTransitions(at: date)
  }

  private func restoreBrightness(stopping: Bool = true) {
    for (id, state) in displayStates where abs(state.current - state.original) > 0.0005 {
      _ = displayProvider.setBrightness(state.original, for: id)
    }
    for (id, state) in keyboardStates where abs(state.current - state.original) > 0.0005 {
      _ = keyboardProvider.setBrightness(state.original, for: id)
    }
    displayStates.removeAll()
    keyboardStates.removeAll()
    if stopping {
      timer?.invalidate()
      timer = nil
    }
  }

  private func ensureTimer() {
    guard schedulesTimer, timer == nil else { return }
    let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refreshBrightness()
      }
    }
    timer.tolerance = 0.002
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func updateTargets(for angle: Double, at date: Date) {
    for id in displayStates.keys {
      guard var state = displayStates[id] else { continue }
      let target = LidBrightnessCurve.targetBrightness(original: state.original, angle: angle)
      guard abs(target - state.target) > 0.0005 else { continue }
      state.transitionFrom = state.current
      state.target = target
      state.transitionStartedAt = date
      displayStates[id] = state
    }

    for id in keyboardStates.keys {
      guard var state = keyboardStates[id] else { continue }
      let target = LidBrightnessCurve.targetKeyboardBrightness(
        original: state.original,
        angle: angle
      )
      guard abs(target - state.target) > 0.0005 else { continue }
      state.transitionFrom = state.current
      state.target = target
      state.transitionStartedAt = date
      keyboardStates[id] = state
    }
  }

  private func advanceTransitions(at date: Date) {
    for id in displayStates.keys {
      guard var state = displayStates[id],
            let transitionStartedAt = state.transitionStartedAt
      else { continue }

      let elapsed = date.timeIntervalSince(transitionStartedAt)
      let progress = min(max(elapsed / Self.transitionDuration, 0), 1)
      let easedProgress = LidBrightnessCurve.smoothProgress(progress)
      let value = state.transitionFrom
        + (state.target - state.transitionFrom) * easedProgress
      guard abs(value - state.current) > 0.0005 else { continue }
      guard displayProvider.setBrightness(value, for: id) else { continue }

      state.current = value
      if progress >= 1 {
        state.current = state.target
        state.transitionStartedAt = nil
      }
      displayStates[id] = state
    }

    for id in keyboardStates.keys {
      guard var state = keyboardStates[id],
            let transitionStartedAt = state.transitionStartedAt
      else { continue }

      let elapsed = date.timeIntervalSince(transitionStartedAt)
      let progress = min(max(elapsed / Self.transitionDuration, 0), 1)
      let easedProgress = LidBrightnessCurve.smoothProgress(progress)
      let value = state.transitionFrom
        + (state.target - state.transitionFrom) * easedProgress
      guard abs(value - state.current) > 0.0005 else { continue }
      guard keyboardProvider.setBrightness(value, for: id) else { continue }

      state.current = value
      if progress >= 1 {
        state.current = state.target
        state.transitionStartedAt = nil
      }
      keyboardStates[id] = state
    }
  }
}
