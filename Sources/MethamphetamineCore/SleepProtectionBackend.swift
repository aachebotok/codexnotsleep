@MainActor
public protocol SleepProtectionBackend: AnyObject {
  var identifier: String { get }
  var isHeld: Bool { get }
  var requiresSetup: Bool { get }
  func prepare() async throws
  func recover() throws
  func acquire() throws
  func renew() throws
  func release() throws
}

public extension SleepProtectionBackend {
  var requiresSetup: Bool { false }
  func prepare() async throws {}
  func recover() throws {}
}
