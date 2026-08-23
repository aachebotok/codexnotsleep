import Darwin
import Foundation

/// A bounded result for a local system command. Output is capped independently
/// for stdout and stderr so a misbehaving child cannot grow the app's memory.
struct BoundedProcessResult: Sendable {
  let status: Int32?
  let stdout: String
  let stderr: String
  let didTimeout: Bool
  let launchError: String?

  var output: String {
    if stderr.isEmpty { return stdout }
    if stdout.isEmpty { return stderr }
    return stdout + stderr
  }

  var succeeded: Bool {
    status == 0 && !didTimeout && launchError == nil
  }

  init(
    status: Int32,
    output: String,
    stderr: String = "",
    didTimeout: Bool = false,
    launchError: String? = nil
  ) {
    self.status = status
    stdout = output
    self.stderr = stderr
    self.didTimeout = didTimeout
    self.launchError = launchError
  }

  init(
    status: Int32?,
    stdout: String = "",
    stderr: String = "",
    didTimeout: Bool = false,
    launchError: String? = nil
  ) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
    self.didTimeout = didTimeout
    self.launchError = launchError
  }
}

protocol BoundedProcessRunning: Sendable {
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?
  ) throws -> BoundedProcessResult
}

extension BoundedProcessRunning {
  func run(executable: String, arguments: [String]) throws -> BoundedProcessResult {
    try run(executable: executable, arguments: arguments, environment: nil)
  }
}

struct BoundedProcessRunner: BoundedProcessRunning {
  static let defaultTimeout: TimeInterval = 10
  static let defaultTerminationGrace: TimeInterval = 0.5
  static let defaultMaximumOutputBytes = 64 * 1_024

  let timeout: TimeInterval
  let terminationGrace: TimeInterval
  let maximumOutputBytes: Int

  init(
    timeout: TimeInterval = Self.defaultTimeout,
    terminationGrace: TimeInterval = Self.defaultTerminationGrace,
    maximumOutputBytes: Int = Self.defaultMaximumOutputBytes
  ) {
    self.timeout = max(timeout, 0.01)
    self.terminationGrace = max(terminationGrace, 0.01)
    self.maximumOutputBytes = max(maximumOutputBytes, 1)
  }

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?
  ) throws -> BoundedProcessResult {
    guard executable.hasPrefix("/") else {
      return BoundedProcessResult(
        status: nil,
        launchError: "Executable path must be absolute"
      )
    }

    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdout = BoundedOutputBuffer(limit: maximumOutputBytes)
    let stderr = BoundedOutputBuffer(limit: maximumOutputBytes)
    let termination = DispatchSemaphore(value: 0)
    let readers = DispatchGroup()

    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { _ in
      termination.signal()
    }

    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      return BoundedProcessResult(
        status: nil,
        launchError: error.localizedDescription
      )
    }

    drain(stdoutPipe.fileHandleForReading, into: stdout, group: readers)
    drain(stderrPipe.fileHandleForReading, into: stderr, group: readers)

    var didTimeout = false
    if termination.wait(timeout: .now() + timeout) == .timedOut {
      didTimeout = true
      terminate(process, semaphore: termination)
    }

    _ = readers.wait(timeout: .now() + terminationGrace)
    try? stdoutPipe.fileHandleForReading.close()
    try? stderrPipe.fileHandleForReading.close()

    return BoundedProcessResult(
      status: process.isRunning ? nil : process.terminationStatus,
      stdout: stdout.string,
      stderr: stderr.string,
      didTimeout: didTimeout
    )
  }

  private func drain(
    _ handle: FileHandle,
    into buffer: BoundedOutputBuffer,
    group: DispatchGroup
  ) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      while true {
        guard let data = try? handle.read(upToCount: 4 * 1_024), !data.isEmpty else { break }
        buffer.append(data)
      }
    }
  }

  private func terminate(_ process: Process, semaphore: DispatchSemaphore) {
    guard process.isRunning else { return }
    process.terminate()
    if semaphore.wait(timeout: .now() + terminationGrace) == .timedOut,
      process.isRunning
    {
      kill(process.processIdentifier, SIGKILL)
      _ = semaphore.wait(timeout: .now() + terminationGrace)
    }
  }
}

private final class BoundedOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var data = Data()

  init(limit: Int) {
    self.limit = limit
  }

  func append(_ value: Data) {
    lock.withLock {
      guard data.count < limit else { return }
      data.append(value.prefix(limit - data.count))
    }
  }

  var string: String {
    lock.withLock { String(decoding: data, as: UTF8.self) }
  }
}

enum BoundedProcessTermination {
  static func stop(_ process: Process, grace: TimeInterval = 0.5) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date.now.addingTimeInterval(max(grace, 0.01))
    while process.isRunning, Date.now < deadline {
      usleep(10_000)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      let killDeadline = Date.now.addingTimeInterval(0.5)
      while process.isRunning, Date.now < killDeadline {
        usleep(10_000)
      }
    }
  }
}
