import Foundation

@MainActor
protocol GraceDeadlineScheduling: AnyObject {
  func schedule(at deadline: Date, handler: @escaping @MainActor @Sendable () -> Void)
  func cancel()
}

@MainActor
final class RunLoopGraceDeadlineScheduler: GraceDeadlineScheduling {
  private var timer: Timer?

  func schedule(at deadline: Date, handler: @escaping @MainActor @Sendable () -> Void) {
    cancel()

    let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.timer = nil
        handler()
      }
    }
    timer.tolerance = 0.1
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func cancel() {
    timer?.invalidate()
    timer = nil
  }
}
