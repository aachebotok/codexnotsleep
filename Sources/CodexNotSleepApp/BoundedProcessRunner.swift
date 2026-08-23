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

    var stdoutPipe = [Int32](repeating: -1, count: 2)
    var stderrPipe = [Int32](repeating: -1, count: 2)
    guard pipe(&stdoutPipe) == 0 else {
      return BoundedProcessResult(status: nil, launchError: "Couldn't create command pipes")
    }
    guard pipe(&stderrPipe) == 0 else {
      closePipe(stdoutPipe)
      return BoundedProcessResult(status: nil, launchError: "Couldn't create command pipes")
    }
    let stdout = BoundedOutputBuffer(limit: maximumOutputBytes)
    let stderr = BoundedOutputBuffer(limit: maximumOutputBytes)
    let termination = DispatchSemaphore(value: 0)
    let readers = DispatchGroup()

    var fileActions: posix_spawn_file_actions_t? = nil
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      closePipe(stdoutPipe)
      closePipe(stderrPipe)
      return BoundedProcessResult(status: nil, launchError: "Couldn't initialize command launch")
    }
    defer {
      posix_spawn_file_actions_destroy(&fileActions)
    }
    var attributes: posix_spawnattr_t? = nil
    guard posix_spawnattr_init(&attributes) == 0 else {
      closePipe(stdoutPipe)
      closePipe(stderrPipe)
      return BoundedProcessResult(status: nil, launchError: "Couldn't initialize command launch")
    }
    defer { posix_spawnattr_destroy(&attributes) }

    guard
      posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO) == 0,
      posix_spawn_file_actions_addopen(
        &fileActions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
      ) == 0,
      posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0]) == 0,
      posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1]) == 0,
      posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0]) == 0,
      posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1]) == 0
    else {
      closePipe(stdoutPipe)
      closePipe(stderrPipe)
      return BoundedProcessResult(status: nil, launchError: "Couldn't initialize command launch")
    }
    let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
    guard
      posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      closePipe(stdoutPipe)
      closePipe(stderrPipe)
      return BoundedProcessResult(status: nil, launchError: "Couldn't initialize command launch")
    }

    let environmentValues = (environment ?? ProcessInfo.processInfo.environment)
      .map { "\($0.key)=\($0.value)" }
    var argumentPointers: [UnsafeMutablePointer<CChar>?] = []
    argumentPointers.reserveCapacity(arguments.count + 2)
    defer {
      for pointer in argumentPointers {
        if let pointer { free(pointer) }
      }
    }
    for value in [executable] + arguments {
      guard let pointer = strdup(value) else {
        closePipe(stdoutPipe)
        closePipe(stderrPipe)
        return BoundedProcessResult(status: nil, launchError: "Couldn't allocate command arguments")
      }
      argumentPointers.append(pointer)
    }
    argumentPointers.append(nil)
    var environmentPointers: [UnsafeMutablePointer<CChar>?] = []
    environmentPointers.reserveCapacity(environmentValues.count + 1)
    defer {
      for pointer in environmentPointers {
        if let pointer { free(pointer) }
      }
    }
    for value in environmentValues {
      guard let pointer = strdup(value) else {
        closePipe(stdoutPipe)
        closePipe(stderrPipe)
        return BoundedProcessResult(
          status: nil, launchError: "Couldn't allocate command environment")
      }
      environmentPointers.append(pointer)
    }
    environmentPointers.append(nil)

    var processID: pid_t = 0
    let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
      environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
        posix_spawn(
          &processID,
          executable,
          &fileActions,
          &attributes,
          argumentBuffer.baseAddress,
          environmentBuffer.baseAddress
        )
      }
    }
    close(stdoutPipe[1])
    close(stderrPipe[1])
    guard spawnResult == 0 else {
      close(stdoutPipe[0])
      close(stderrPipe[0])
      return BoundedProcessResult(
        status: nil,
        launchError: String(cString: strerror(spawnResult))
      )
    }

    let stdoutHandle = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
    let stderrHandle = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
    drain(stdoutHandle, into: stdout, group: readers)
    drain(stderrHandle, into: stderr, group: readers)

    let waitState = SpawnedProcessWaitState()
    let spawnedProcessID = processID
    DispatchQueue.global(qos: .utility).async {
      var rawStatus: Int32 = 0
      while waitpid(spawnedProcessID, &rawStatus, 0) < 0, errno == EINTR {}
      waitState.finish(rawStatus)
      termination.signal()
    }

    var didTimeout = false
    if termination.wait(timeout: .now() + timeout) == .timedOut {
      didTimeout = true
      terminate(processID, semaphore: termination, waitState: waitState)
    }

    if !waitState.hasExited {
      _ = termination.wait(timeout: .now() + terminationGrace)
    }
    if !waitState.hasExited {
      kill(-processID, SIGKILL)
      kill(processID, SIGKILL)
      _ = termination.wait(timeout: .now() + terminationGrace)
    }
    // Reap the direct child even if the bounded grace period was exhausted.
    if !waitState.hasExited { termination.wait() }

    _ = readers.wait(timeout: .now() + terminationGrace)
    try? stdoutHandle.close()
    try? stderrHandle.close()

    return BoundedProcessResult(
      status: waitState.terminationStatus,
      stdout: stdout.string,
      stderr: stderr.string,
      didTimeout: didTimeout
    )
  }

  private func closePipe(_ pipe: [Int32]) {
    for descriptor in pipe where descriptor >= 0 {
      close(descriptor)
    }
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

  private func terminate(
    _ processID: pid_t,
    semaphore: DispatchSemaphore,
    waitState: SpawnedProcessWaitState
  ) {
    guard !waitState.hasExited else { return }
    kill(-processID, SIGTERM)
    kill(processID, SIGTERM)
    if semaphore.wait(timeout: .now() + terminationGrace) == .timedOut,
      !waitState.hasExited
    {
      kill(-processID, SIGKILL)
      kill(processID, SIGKILL)
      _ = semaphore.wait(timeout: .now() + terminationGrace)
    }
  }
}

private final class SpawnedProcessWaitState: @unchecked Sendable {
  private let lock = NSLock()
  private var rawStatus: Int32?

  func finish(_ status: Int32) {
    lock.withLock { rawStatus = status }
  }

  var hasExited: Bool {
    lock.withLock { rawStatus != nil }
  }

  var terminationStatus: Int32? {
    lock.withLock { () -> Int32? in
      guard let rawStatus else { return nil }
      if rawStatus & 0x7F == 0 { return (rawStatus >> 8) & 0xFF }
      if rawStatus & 0x7F != 0 { return -Int32(rawStatus & 0x7F) }
      return nil
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
    guard process.isRunning else {
      process.waitUntilExit()
      return
    }
    kill(-process.processIdentifier, SIGTERM)
    process.terminate()
    let deadline = Date.now.addingTimeInterval(max(grace, 0.01))
    while process.isRunning, Date.now < deadline {
      usleep(10_000)
    }
    if process.isRunning {
      kill(-process.processIdentifier, SIGKILL)
      kill(process.processIdentifier, SIGKILL)
      let killDeadline = Date.now.addingTimeInterval(0.5)
      while process.isRunning, Date.now < killDeadline {
        usleep(10_000)
      }
    }
    process.waitUntilExit()
  }
}
