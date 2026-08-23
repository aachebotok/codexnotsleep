import AppKit
import CoreFoundation
import CoreGraphics
import Darwin
import IOKit
import IOKit.hid
import ObjectiveC.runtime

@MainActor
protocol LidAngleProviding: AnyObject {
  func currentAngle() -> Double?
  func startMonitoring(onChange: @escaping (Double) -> Void)
  func stopMonitoring()
}

extension LidAngleProviding {
  func startMonitoring(onChange: @escaping (Double) -> Void) {}
  func stopMonitoring() {}
}

enum LidSensorConnectionState: Equatable, Sendable {
  case stopped
  case managerReady
  case deviceReady
}

struct LidSensorConnectionStateMachine: Equatable, Sendable {
  private(set) var state: LidSensorConnectionState = .stopped

  mutating func managerOpened() {
    state = .managerReady
  }

  mutating func deviceAttached() {
    state = .deviceReady
  }

  mutating func deviceDetached() {
    state = .managerReady
  }

  mutating func stopped() {
    state = .stopped
  }
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
  private var angleHandler: ((Double) -> Void)?
  private var callbackQueue: DispatchQueue?
  private var connectionStateMachine = LidSensorConnectionStateMachine()

  var connectionState: LidSensorConnectionState { connectionStateMachine.state }

  func currentAngle() -> Double? {
    guard ensureDevice() else { return nil }
    guard let device, let angleElement else {
      detachDevice()
      return nil
    }

    guard let rawAngle = Self.readAngle(device: device, element: angleElement) else {
      detachDevice()
      return nil
    }

    // Apple reports `1` for the docked/fully closed position on this sensor.
    return rawAngle <= 1
      ? 0
      : min(Double(rawAngle), LidBrightnessCurve.sensorMaximumAngle)
  }

  func startMonitoring(onChange: @escaping (Double) -> Void) {
    angleHandler = onChange
    _ = ensureManager()
    _ = attachMatchingDevice()
    if let angle = currentAngle() {
      onChange(angle)
    }
  }

  func stopMonitoring() {
    angleHandler = nil
    stopManager()
  }

  private func ensureDevice() -> Bool {
    if device != nil { return true }
    _ = ensureManager()
    return attachMatchingDevice()
  }

  private func ensureManager() -> Bool {
    guard manager == nil else { return true }
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

    let callbackQueue = DispatchQueue(
      label: "app.codexnotsleep.lid-angle-events",
      qos: .userInitiated
    )
    IOHIDManagerRegisterInputValueCallback(
      manager,
      Self.inputValueCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
    IOHIDManagerRegisterDeviceMatchingCallback(
      manager,
      Self.deviceMatchingCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
    IOHIDManagerRegisterDeviceRemovalCallback(
      manager,
      Self.deviceRemovalCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
    IOHIDManagerSetDispatchQueue(manager, callbackQueue)
    self.callbackQueue = callbackQueue
    self.manager = manager

    guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    else {
      self.manager = nil
      self.callbackQueue = nil
      return false
    }
    connectionStateMachine.managerOpened()
    return true
  }

  private func attachMatchingDevice() -> Bool {
    if device != nil { return true }
    guard let manager else { return false }
    guard let devices = IOHIDManagerCopyDevices(manager) else {
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
      connectionStateMachine.deviceAttached()
      return true
    }

    return false
  }

  private static func findAngleElement(on device: IOHIDDevice) -> IOHIDElement? {
    guard
      let elements = IOHIDDeviceCopyMatchingElements(
        device,
        nil,
        IOOptionBits(kIOHIDOptionsTypeNone)
      )
    else {
      return nil
    }

    let count = CFArrayGetCount(elements)
    for index in 0..<count {
      guard let rawElement = CFArrayGetValueAtIndex(elements, index) else { continue }
      let element = Unmanaged<IOHIDElement>.fromOpaque(rawElement).takeUnretainedValue()
      guard IOHIDElementGetUsagePage(element) == Self.usagePage,
        IOHIDElementGetUsage(element) == Self.angleUsage,
        IOHIDElementGetType(element) == kIOHIDElementTypeInput_Axis
          || IOHIDElementGetType(element) == kIOHIDElementTypeInput_Misc
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

  private func detachDevice() {
    angleElement = nil
    if let device {
      IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
      self.device = nil
    }
    if manager != nil {
      connectionStateMachine.deviceDetached()
    }
  }

  private func stopManager() {
    detachDevice()
    if let manager {
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
      self.manager = nil
    }
    callbackQueue = nil
    connectionStateMachine.stopped()
  }

  private func handleInputValue(_ value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    guard IOHIDElementGetUsagePage(element) == Self.usagePage,
      IOHIDElementGetUsage(element) == Self.angleUsage
    else { return }

    let rawAngle = IOHIDValueGetIntegerValue(value)
    let angle =
      rawAngle <= 1
      ? 0.0
      : min(Double(rawAngle), LidBrightnessCurve.sensorMaximumAngle)
    Task { @MainActor [weak self] in
      self?.angleHandler?(angle)
    }
  }

  private func handleDeviceMatching() {
    Task { @MainActor [weak self] in
      guard let self, self.angleHandler != nil, self.device == nil else { return }
      guard attachMatchingDevice(), let angle = currentAngle() else { return }
      angleHandler?(angle)
    }
  }

  private func handleDeviceRemoval() {
    Task { @MainActor [weak self] in
      guard let self, self.angleHandler != nil else { return }
      detachDevice()
    }
  }

  private static let inputValueCallback: IOHIDValueCallback = {
    context, _, _, value in
    guard let context else { return }
    let sensor = Unmanaged<IOKitLidAngleSensor>
      .fromOpaque(context)
      .takeUnretainedValue()
    sensor.handleInputValue(value)
  }

  private static let deviceMatchingCallback: IOHIDDeviceCallback = {
    context, _, _, _ in
    guard let context else { return }
    let sensor = Unmanaged<IOKitLidAngleSensor>
      .fromOpaque(context)
      .takeUnretainedValue()
    sensor.handleDeviceMatching()
  }

  private static let deviceRemovalCallback: IOHIDDeviceCallback = {
    context, _, _, _ in
    guard let context else { return }
    let sensor = Unmanaged<IOKitLidAngleSensor>
      .fromOpaque(context)
      .takeUnretainedValue()
    sensor.handleDeviceRemoval()
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
  private typealias BrightnessFunction =
    @convention(c) (
      AnyObject,
      Selector,
      UInt64
    ) -> Float
  private typealias IsBuiltInFunction =
    @convention(c) (
      AnyObject,
      Selector,
      UInt64
    ) -> Bool
  private typealias SetBrightnessFunction =
    @convention(c) (
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
  private typealias GetBrightnessFunction =
    @convention(c) (
      CGDirectDisplayID,
      UnsafeMutablePointer<Float>
    ) -> Int32
  private typealias SetBrightnessFunction =
    @convention(c) (
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

    // DisplayServices accepts the exact CGDirectDisplayID. If it is not
    // available, fail safely instead of guessing from the first IODisplayConnect
    // service, which can be an external display.
    guard let setDisplayServicesBrightness else { return false }
    return setDisplayServicesBrightness(displayID, value) == kIOReturnSuccess
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

    return nil
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
  private static let transitionCompletionTolerance: TimeInterval = 0.001

  private let angleSensor: any LidAngleProviding
  private let displayProvider: any DisplayBrightnessProviding
  private let keyboardProvider: any KeyboardBacklightProviding
  private let schedulesTimer: Bool
  private var displayStates: [UInt32: BrightnessState] = [:]
  private var keyboardStates: [UInt64: BrightnessState] = [:]
  private var timer: Timer?
  private var isCodexWorking = false
  private var isBrightnessFeatureDisabled = false

  var isInterpolationTimerActive: Bool { timer != nil }

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
        isBrightnessFeatureDisabled = false
        angleSensor.startMonitoring { [weak self] angle in
          self?.handleAngle(angle)
        }
        refreshBrightness()
      }
      return
    }

    guard isCodexWorking || !displayStates.isEmpty || !keyboardStates.isEmpty else { return }
    isCodexWorking = false
    angleSensor.stopMonitoring()
    restoreBrightness()
  }

  func reset() {
    isCodexWorking = false
    angleSensor.stopMonitoring()
    restoreBrightness(stopping: true)
  }

  func refreshBrightness(at date: Date = .now) {
    guard isCodexWorking else { return }
    refreshBrightness(at: date, angle: angleSensor.currentAngle())
  }

  private func handleAngle(_ angle: Double) {
    refreshBrightness(at: .now, angle: angle)
  }

  private func refreshBrightness(at date: Date, angle: Double?) {
    guard isCodexWorking, !isBrightnessFeatureDisabled else { return }

    if let angle {
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
    var displayRestored = Set<UInt32>()
    for (id, state) in displayStates {
      guard abs(state.current - state.original) > 0.0005 else {
        displayRestored.insert(id)
        continue
      }
      if displayProvider.setBrightness(state.original, for: id) {
        displayRestored.insert(id)
      }
    }
    for id in displayRestored {
      displayStates.removeValue(forKey: id)
    }

    var keyboardRestored = Set<UInt64>()
    for (id, state) in keyboardStates {
      guard abs(state.current - state.original) > 0.0005 else {
        keyboardRestored.insert(id)
        continue
      }
      if keyboardProvider.setBrightness(state.original, for: id) {
        keyboardRestored.insert(id)
      }
    }
    for id in keyboardRestored {
      keyboardStates.removeValue(forKey: id)
    }

    timer?.invalidate()
    timer = nil
    if stopping {
      angleSensor.stopMonitoring()
    }
  }

  private func ensureTimer() {
    guard schedulesTimer, timer == nil else { return }
    let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.advanceTransitions(at: .now)
      }
    }
    timer.tolerance = 0.002
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func updateTargets(for angle: Double, at date: Date) {
    var hasTransition = false
    for id in displayStates.keys {
      guard var state = displayStates[id] else { continue }
      let target = LidBrightnessCurve.targetBrightness(original: state.original, angle: angle)
      guard abs(target - state.target) > 0.0005 else { continue }
      state.transitionFrom = state.current
      state.target = target
      state.transitionStartedAt = date
      hasTransition = true
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
      hasTransition = true
      keyboardStates[id] = state
    }
    if hasTransition { ensureTimer() }
  }

  private func advanceTransitions(at date: Date) {
    var writeFailed = false
    for id in displayStates.keys {
      guard var state = displayStates[id],
        let transitionStartedAt = state.transitionStartedAt
      else { continue }

      let elapsed = date.timeIntervalSince(transitionStartedAt)
      let isComplete = elapsed >= Self.transitionDuration - Self.transitionCompletionTolerance
      let progress =
        isComplete
        ? 1
        : min(max(elapsed / Self.transitionDuration, 0), 1)
      let easedProgress = LidBrightnessCurve.smoothProgress(progress)
      let value =
        state.transitionFrom
        + (state.target - state.transitionFrom) * easedProgress
      if abs(value - state.current) > 0.0005 {
        guard displayProvider.setBrightness(value, for: id) else {
          writeFailed = true
          break
        }
        state.current = value
      }

      if isComplete {
        state.current = state.target
        state.transitionStartedAt = nil
      }
      displayStates[id] = state
    }

    if writeFailed {
      disableBrightnessFeature()
      return
    }

    for id in keyboardStates.keys {
      guard var state = keyboardStates[id],
        let transitionStartedAt = state.transitionStartedAt
      else { continue }

      let elapsed = date.timeIntervalSince(transitionStartedAt)
      let isComplete = elapsed >= Self.transitionDuration - Self.transitionCompletionTolerance
      let progress =
        isComplete
        ? 1
        : min(max(elapsed / Self.transitionDuration, 0), 1)
      let easedProgress = LidBrightnessCurve.smoothProgress(progress)
      let value =
        state.transitionFrom
        + (state.target - state.transitionFrom) * easedProgress
      if abs(value - state.current) > 0.0005 {
        guard keyboardProvider.setBrightness(value, for: id) else {
          writeFailed = true
          break
        }
        state.current = value
      }

      if isComplete {
        state.current = state.target
        state.transitionStartedAt = nil
      }
      keyboardStates[id] = state
    }

    if writeFailed {
      disableBrightnessFeature()
      return
    }

    let hasActiveTransition =
      displayStates.values.contains { $0.transitionStartedAt != nil }
      || keyboardStates.values.contains { $0.transitionStartedAt != nil }
    if !hasActiveTransition {
      timer?.invalidate()
      timer = nil
    }
  }

  private func disableBrightnessFeature() {
    isBrightnessFeatureDisabled = true
    restoreBrightness(stopping: false)
  }
}
