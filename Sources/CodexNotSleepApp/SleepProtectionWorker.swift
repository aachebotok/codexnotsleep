import CodexNotSleepCore
import Foundation

/// Runs blocking power-management work on a dedicated serial queue.
// The queue is the sole owner of backend calls and ordering. This narrow
// boundary lets those calls leave the main actor without making every
// platform backend Sendable.
final class SleepProtectionWorker: @unchecked Sendable {
  private let backend: any SleepProtectionBackend
  private let queue = DispatchQueue(
    label: "app.codexnotsleep.sleep-protection-worker",
    qos: .utility
  )

  init(backend: any SleepProtectionBackend) {
    self.backend = backend
  }

  func recover(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    submit({ try $0.recover() }, completion: completion)
  }

  func prepare(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    submit({ try $0.prepare() }, completion: completion)
  }

  func prepareClosedLid(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    submit(
      { backend in
        guard let manager = backend as? any ClosedLidProtectionManaging else {
          return
        }
        try manager.prepareClosedLid()
      }, completion: completion)
  }

  func inspectClosedLidSetup(
    completion: @escaping @MainActor @Sendable (PowerProtectSetupState) -> Void
  ) {
    queue.async { [self] in
      let state =
        (self.backend as? any ClosedLidProtectionInspecting)?.closedLidSetupState
        ?? .unavailable
      DispatchQueue.main.async {
        completion(state)
      }
    }
  }

  func releaseClosedLid(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    submit(
      { backend in
        guard let manager = backend as? any ClosedLidProtectionReleasing else {
          return
        }
        try manager.releaseClosedLid()
      }, completion: completion)
  }

  func setClosedLidEnabled(
    _ enabled: Bool,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    submit(
      { backend in
        guard let manager = backend as? any ClosedLidProtectionManaging else {
          return
        }
        manager.setClosedLidEnabled(enabled)
      }, completion: completion)
  }

  func acquire(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    submit({ try $0.acquire() }, completion: completion)
  }

  func renew(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    submit({ try $0.renew() }, completion: completion)
  }

  func release(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    submit({ try $0.release() }, completion: completion)
  }

  private func submit(
    _ operation: @escaping @Sendable (any SleepProtectionBackend) throws -> Void,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    queue.async { [self] in
      let result: Result<Void, Error>
      do {
        try operation(self.backend)
        result = .success(())
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }
}
