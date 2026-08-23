import CodexNotSleepCore
import Darwin
import Foundation

enum PowerProtectError: LocalizedError, Equatable {
  case setupCancelled
  case setupFailed
  case setupVerificationFailed
  case setupRequired
  case commandFailed
  case restoreFailed
  case stateVerificationFailed
  case watchdogFailed

  var errorDescription: String? {
    switch self {
    case .setupCancelled:
      "Setup canceled"
    case .setupFailed, .setupVerificationFailed:
      "Couldn't set up closed-lid operation"
    case .setupRequired:
      "Closed-lid operation requires a one-time setup"
    case .commandFailed:
      "Couldn't prevent sleep with the lid closed"
    case .restoreFailed, .stateVerificationFailed:
      "Couldn't restore normal sleep"
    case .watchdogFailed:
      "Couldn't start crash recovery"
    }
  }
}

enum PowerProtectSetupState: Equatable, Sendable {
  case notInstalled
  case installedAndValid
  case installedButInvalid
  case unavailable
}

enum ClosedLidProtectionError: LocalizedError, Equatable {
  case setupRequired
  case acquisitionFailed
  case renewalFailed
  case releaseFailed
  case recoveryFailed

  var errorDescription: String? {
    switch self {
    case .setupRequired:
      "Closed-lid protection needs one-time setup"
    case .acquisitionFailed:
      "Closed-lid protection could not be acquired"
    case .renewalFailed:
      "Closed-lid protection could not be renewed"
    case .releaseFailed:
      "Closed-lid protection could not be released"
    case .recoveryFailed:
      "Closed-lid protection could not be recovered"
    }
  }
}

protocol ClosedLidProtectionManaging: AnyObject {
  var isClosedLidEnabled: Bool { get }
  func setClosedLidEnabled(_ enabled: Bool)
  func prepareClosedLid() throws
}

protocol ClosedLidProtectionInspecting: AnyObject {
  var closedLidSetupState: PowerProtectSetupState { get }
}

protocol ClosedLidProtectionReleasing: AnyObject {
  func releaseClosedLid() throws
}

typealias PowerProtectCommandResult = BoundedProcessResult
typealias PowerProtectCommandRunning = BoundedProcessRunning
typealias ProcessPowerProtectCommandRunner = BoundedProcessRunner

enum PowerProtectAuthorizationEnvironment {
  private static let removedNames: Set<String> = [
    "BASHOPTS", "BASH_ENV", "CDPATH", "ENV", "FPATH", "GLOBIGNORE", "IFS", "PS4",
    "SHELLOPTS", "ZDOTDIR",
  ]
  private static let removedPrefixes = ["BASH_FUNC_", "DYLD_", "LD_"]
  private static let fixedValues = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "C",
    "LC_ALL": "C",
  ]

  static func sanitized(_ environment: [String: String]) -> [String: String] {
    var result = environment.filter { key, _ in
      !removedNames.contains(key)
        && !removedPrefixes.contains(where: key.hasPrefix)
    }
    result.merge(fixedValues) { _, fixed in fixed }
    return result
  }

  static func applyToCurrentProcess() {
    let current = ProcessInfo.processInfo.environment
    let sanitizedEnvironment = sanitized(current)
    for key in current.keys where sanitizedEnvironment[key] == nil {
      unsetenv(key)
    }
    for (key, value) in fixedValues {
      setenv(key, value, 1)
    }
  }
}

protocol PowerProtectAuthorizationRunning: AnyObject {
  func run(script source: String) -> PowerProtectCommandResult
}

final class NSAppleScriptPowerProtectAuthorizationRunner: PowerProtectAuthorizationRunning {
  func run(script source: String) -> PowerProtectCommandResult {
    PowerProtectAuthorizationEnvironment.applyToCurrentProcess()
    guard let script = NSAppleScript(source: source) else {
      return PowerProtectCommandResult(status: 1, output: "AppleScript initialization failed")
    }

    var errorInfo: NSDictionary?
    let descriptor = script.executeAndReturnError(&errorInfo)
    guard let errorInfo else {
      return PowerProtectCommandResult(status: 0, output: descriptor.stringValue ?? "")
    }

    let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? 1
    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
    return PowerProtectCommandResult(status: number == 0 ? 1 : number, output: message)
  }
}

protocol PowerProtectInstalling: AnyObject {
  var setupState: PowerProtectSetupState { get }
  var hasRuleFile: Bool { get }
  var isInstalled: Bool { get }
  func install() throws
}

struct PowerProtectRuleFileState: Equatable, Sendable {
  let exists: Bool
  let isRegularFile: Bool
  let ownerID: uid_t?
  let permissions: UInt16?

  static let notInstalled = PowerProtectRuleFileState(
    exists: false,
    isRegularFile: false,
    ownerID: nil,
    permissions: nil
  )
}

final class PowerProtectInstaller: PowerProtectInstalling {
  static let authorizationPrompt =
    "Allow Codexetine to keep your Mac running with the lid closed. You'll only need to confirm once."

  static var authorizationPreviewAppleScript: String {
    "do shell script \"/usr/bin/true\" with prompt \"\(authorizationPrompt)\" with administrator privileges"
  }

  var setupState: PowerProtectSetupState {
    let fileState = fileStateProvider()
    guard fileState.exists else { return .notInstalled }
    guard
      fileState.isRegularFile,
      fileState.ownerID == 0,
      fileState.permissions == 0o440
    else { return .installedButInvalid }
    return Self.verifyInstallation(using: runner) ? .installedAndValid : .installedButInvalid
  }

  var hasRuleFile: Bool { fileStateProvider().exists }
  var isInstalled: Bool { setupState == .installedAndValid }
  private let runner: any PowerProtectCommandRunning
  private let authorizationRunner: any PowerProtectAuthorizationRunning
  private let userID: uid_t
  private let sudoersPath: String
  private let fileStateProvider: () -> PowerProtectRuleFileState

  init(
    runner: any PowerProtectCommandRunning = ProcessPowerProtectCommandRunner(),
    authorizationRunner: any PowerProtectAuthorizationRunning =
      NSAppleScriptPowerProtectAuthorizationRunner(),
    userID: uid_t = getuid(),
    fileManager: FileManager = .default,
    installationCheck: (() -> Bool)? = nil,
    fileStateProvider: (() -> PowerProtectRuleFileState)? = nil
  ) {
    self.runner = runner
    self.authorizationRunner = authorizationRunner
    self.userID = userID
    let sudoersPath = Self.sudoersPath(for: userID)
    self.sudoersPath = sudoersPath
    if let fileStateProvider {
      self.fileStateProvider = fileStateProvider
    } else if let installationCheck {
      self.fileStateProvider = {
        installationCheck()
          ? PowerProtectRuleFileState(
            exists: true,
            isRegularFile: true,
            ownerID: 0,
            permissions: 0o440
          )
          : .notInstalled
      }
    } else {
      self.fileStateProvider = {
        guard
          let attributes = try? fileManager.attributesOfItem(atPath: sudoersPath),
          let type = attributes[.type] as? FileAttributeType,
          let ownerID = attributes[.ownerAccountID] as? NSNumber,
          let permissions = attributes[.posixPermissions] as? NSNumber
        else { return .notInstalled }
        return PowerProtectRuleFileState(
          exists: true,
          isRegularFile: type == .typeRegular,
          ownerID: ownerID.uint32Value,
          permissions: UInt16(truncating: permissions)
        )
      }
    }
  }

  func install() throws {
    if isInstalled { return }

    let result = authorizationRunner.run(script: administratorAppleScript)

    guard result.succeeded else {
      if result.status == -128 {
        throw PowerProtectError.setupCancelled
      }
      throw PowerProtectError.setupFailed
    }
    guard fileStateProvider().exists else {
      throw PowerProtectError.setupVerificationFailed
    }

    guard isInstalled else {
      throw PowerProtectError.setupVerificationFailed
    }
  }

  private nonisolated static let verificationArgumentSets = [
    ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"],
    ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"],
  ]

  nonisolated static func sudoersPath(for userID: uid_t) -> String {
    // Keep the historical path so existing installations can be recovered and removed.
    "/private/etc/sudoers.d/methamphetamine_power_protect_\(userID)"
  }

  private nonisolated static func verifyInstallation(
    using runner: any PowerProtectCommandRunning
  ) -> Bool {
    for arguments in verificationArgumentSets {
      guard
        let result = try? runner.run(
          executable: "/usr/bin/sudo",
          arguments: arguments,
          environment: PowerProtectAuthorizationEnvironment.sanitized(
            ProcessInfo.processInfo.environment
          )
        ),
        result.succeeded
      else { return false }
    }
    return true
  }

  private var administratorAppleScript: String {
    let encodedScript = Data(installerShellScript.utf8).base64EncodedString()
    return
      "do shell script \"/bin/echo '\(encodedScript)' | /usr/bin/base64 -D | /bin/sh\" with prompt \"\(Self.authorizationPrompt)\" with administrator privileges"
  }

  private var installerShellScript: String {
    let userRule =
      "#\(userID) ALL=(root) NOPASSWD:NOSETENV: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    return
      """
      set -eu
      target='\(sudoersPath)'
      temporary=$(/usr/bin/mktemp "${target}.XXXXXX")
      cleanup() { /bin/rm -f "$temporary"; }
      trap cleanup EXIT HUP INT TERM
      /usr/bin/printf '%s\n' '\(userRule)' > "$temporary"
      /usr/sbin/chown root:wheel "$temporary"
      /bin/chmod 0440 "$temporary"
      /usr/sbin/visudo -cf "$temporary"
      /bin/mv -f "$temporary" "$target"
      trap - EXIT HUP INT TERM
      """
  }
}

protocol PowerProtectWatchdogControlling: AnyObject {
  func start(parentPID: Int32, leaseURL: URL, token: String) throws
  func stop()
}

final class ProcessPowerProtectWatchdog: PowerProtectWatchdogControlling {
  private var process: Process?
  private var parentWriteHandle: FileHandle?

  func start(parentPID: Int32, leaseURL: URL, token: String) throws {
    stop()

    let process = Process()
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = ["-c", Self.watchdogScript]
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "C",
      "LC_ALL": "C",
      "CNS_PARENT_PID": String(parentPID),
      "CNS_LEASE_PATH": leaseURL.path,
      "CNS_LEASE_TOKEN": token,
    ]
    let readinessPipe = Pipe()
    let parentPipe = Pipe()
    process.standardOutput = readinessPipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = parentPipe.fileHandleForReading

    do {
      try process.run()
      let readiness = Self.readinessData(
        from: readinessPipe.fileHandleForReading,
        timeout: 2
      )
      guard readiness == Data("ready\n".utf8), process.isRunning else {
        BoundedProcessTermination.stop(process)
        try? parentPipe.fileHandleForWriting.close()
        throw PowerProtectError.watchdogFailed
      }
      self.process = process
      self.parentWriteHandle = parentPipe.fileHandleForWriting
    } catch {
      try? parentPipe.fileHandleForWriting.close()
      throw PowerProtectError.watchdogFailed
    }
  }

  func stop() {
    try? parentWriteHandle?.close()
    parentWriteHandle = nil
    guard let process else { return }
    BoundedProcessTermination.stop(process)
    self.process = nil
  }

  private static func readinessData(from handle: FileHandle, timeout: TimeInterval) -> Data? {
    var descriptor = pollfd(
      fd: handle.fileDescriptor,
      events: Int16(POLLIN),
      revents: 0
    )
    let milliseconds = Int32(min(max(timeout, 0.01) * 1_000, Double(Int32.max)))
    guard Darwin.poll(&descriptor, 1, milliseconds) > 0 else { return nil }
    return try? handle.read(upToCount: 6)
  }

  static let watchdogScript =
    """
    /usr/bin/printf 'ready\n'
    # Parent liveness is authorized by EOF on the inherited pipe. The parent
    # PID is diagnostic metadata only and is never used for restoration.
    /bin/cat </dev/stdin >/dev/null
    run_bounded() {
      directory=$(/usr/bin/mktemp -d "${CNS_LEASE_PATH}.watchdog.XXXXXX") || return 124
      "$@" >"$directory/output" 2>/dev/null &
      child=$!
      ticks=0
      while /bin/kill -0 "$child" 2>/dev/null; do
        if [ "$ticks" -ge 20 ]; then
          /bin/kill -TERM "$child" 2>/dev/null || true
          /bin/sleep 0.1
          /bin/kill -KILL "$child" 2>/dev/null || true
          /bin/wait "$child" 2>/dev/null || true
          /bin/rm -rf "$directory"
          return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
      done
      /bin/wait "$child"
      status=$?
      /bin/cat "$directory/output"
      /bin/rm -rf "$directory"
      return "$status"
    }
    retry_count=0
    maximum_retries=6
    retry_delay=0.25
    while [ "$(/bin/cat "$CNS_LEASE_PATH" 2>/dev/null)" = "$CNS_LEASE_TOKEN" ]; do
      current=$(run_bounded /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }') || current=""
      if [ "$current" = "0" ]; then
        /bin/rm -f "$CNS_LEASE_PATH"
        exit 0
      fi
      run_bounded /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
      current=$(run_bounded /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }') || current=""
      if [ "$current" = "0" ]; then
        /bin/rm -f "$CNS_LEASE_PATH"
        exit 0
      fi
      if [ "$retry_count" -ge "$maximum_retries" ]; then
        # Keep the lease for explicit recovery when the finite retry budget is
        # exhausted; never authorize an unbounded restoration loop.
        exit 75
      fi
      retry_count=$((retry_count + 1))
      /bin/sleep "$retry_delay"
      case "$retry_delay" in
        0.25) retry_delay=0.5 ;;
        0.5) retry_delay=1 ;;
        1) retry_delay=2 ;;
        2) retry_delay=4 ;;
        *) retry_delay=5 ;;
      esac
    done
    """
}

final class PowerProtectLeaseStore {
  let url: URL
  private let fileManager: FileManager

  init(url: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    if let url {
      self.url = url
    } else {
      let applicationSupport =
        fileManager.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first
        ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
      self.url =
        applicationSupport
        // Keep the legacy directory so an update can recover an old lease.
        .appending(path: "Methamphetamine", directoryHint: .isDirectory)
        .appending(path: "power-protect.lease")
    }
  }

  var hasLease: Bool {
    fileManager.fileExists(atPath: url.path)
  }

  func begin() throws -> String {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let token = UUID().uuidString
    try Data(token.utf8).write(to: url, options: .atomic)
    return token
  }

  func finish() throws {
    if hasLease { try fileManager.removeItem(at: url) }
  }
}

final class PMSetPowerProtectBackend: SleepProtectionBackend,
  ClosedLidProtectionManaging, ClosedLidProtectionInspecting, ClosedLidProtectionReleasing
{
  let identifier = "pmset closed-lid protection"
  private(set) var isHeld: Bool
  private(set) var isClosedLidEnabled: Bool
  var closedLidSetupState: PowerProtectSetupState { installer.setupState }

  // Presence is cheap and safe during app startup. Semantic permission
  // verification is deferred to the worker that performs acquire/release.
  var requiresSetup: Bool { !installer.hasRuleFile }

  private let installer: any PowerProtectInstalling
  private let runner: any PowerProtectCommandRunning
  private let leaseStore: PowerProtectLeaseStore
  private let watchdog: any PowerProtectWatchdogControlling
  private var inheritedDisabledSleep = false

  init(
    installer: (any PowerProtectInstalling)? = nil,
    runner: any PowerProtectCommandRunning = ProcessPowerProtectCommandRunner(),
    leaseStore: PowerProtectLeaseStore = PowerProtectLeaseStore(),
    watchdog: any PowerProtectWatchdogControlling = ProcessPowerProtectWatchdog(),
    closedLidEnabled: Bool = true
  ) {
    self.runner = runner
    self.leaseStore = leaseStore
    self.watchdog = watchdog
    self.installer = installer ?? PowerProtectInstaller(runner: runner)
    isHeld = leaseStore.hasLease
    isClosedLidEnabled = closedLidEnabled
  }

  func prepare() throws {
    try prepareClosedLid()
  }

  func prepareClosedLid() throws {
    try installer.install()
  }

  func setClosedLidEnabled(_ enabled: Bool) {
    isClosedLidEnabled = enabled
  }

  func recover() throws {
    guard leaseStore.hasLease else { return }
    try restoreSleep()
  }

  func acquire() throws {
    guard !isHeld else { return }
    guard !requiresSetup, installer.isInstalled else {
      throw PowerProtectError.setupRequired
    }

    if try sleepIsDisabled() {
      inheritedDisabledSleep = true
      isHeld = true
      return
    }

    inheritedDisabledSleep = false
    try beginOwnedProtection()
  }

  func renew() throws {
    guard isHeld else { return }
    if try sleepIsDisabled() {
      return
    }

    if inheritedDisabledSleep {
      inheritedDisabledSleep = false
      isHeld = false
      try beginOwnedProtection()
    } else {
      guard leaseStore.hasLease else {
        isHeld = false
        throw PowerProtectError.stateVerificationFailed
      }
      try activateOwnedProtection()
    }
  }

  private func beginOwnedProtection() throws {
    let token = try leaseStore.begin()
    do {
      try watchdog.start(
        parentPID: ProcessInfo.processInfo.processIdentifier,
        leaseURL: leaseStore.url,
        token: token
      )
      isHeld = true
      try activateOwnedProtection()
    } catch {
      let activationError = error
      do {
        try restoreSleep()
      } catch {
        throw error
      }
      throw activationError
    }
  }

  private func activateOwnedProtection() throws {
    try setSleepDisabled(true)
    guard try sleepIsDisabled() else {
      throw PowerProtectError.stateVerificationFailed
    }
  }

  func release() throws {
    guard isHeld || leaseStore.hasLease else { return }
    if inheritedDisabledSleep && !leaseStore.hasLease {
      inheritedDisabledSleep = false
      isHeld = false
      return
    }
    try restoreSleep()
  }

  func releaseClosedLid() throws {
    try release()
  }

  private func restoreSleep() throws {
    do {
      if try sleepIsDisabled() {
        guard !requiresSetup else { throw PowerProtectError.setupRequired }
        try setSleepDisabled(false)
        guard try !sleepIsDisabled() else {
          throw PowerProtectError.stateVerificationFailed
        }
      }
      try leaseStore.finish()
      watchdog.stop()
      inheritedDisabledSleep = false
      isHeld = false
    } catch {
      isHeld = leaseStore.hasLease
      throw PowerProtectError.restoreFailed
    }
  }

  private func setSleepDisabled(_ isDisabled: Bool) throws {
    let result = try runner.run(
      executable: "/usr/bin/sudo",
      arguments: [
        "-n", "/usr/bin/pmset", "-a", "disablesleep", isDisabled ? "1" : "0",
      ],
      environment: Self.sanitizedEnvironment
    )
    guard result.succeeded else {
      throw isDisabled ? PowerProtectError.commandFailed : PowerProtectError.restoreFailed
    }
  }

  private func sleepIsDisabled() throws -> Bool {
    let result = try runner.run(
      executable: "/usr/bin/pmset",
      arguments: ["-g"],
      environment: Self.sanitizedEnvironment
    )
    guard result.succeeded else { throw PowerProtectError.stateVerificationFailed }
    for line in result.output.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.first == "SleepDisabled", let value = fields.last {
        return value == "1"
      }
    }
    return false
  }

  private static let sanitizedEnvironment =
    PowerProtectAuthorizationEnvironment.sanitized(ProcessInfo.processInfo.environment)
}

final class CombinedSleepProtectionBackend: SleepProtectionBackend,
  ClosedLidProtectionManaging, ClosedLidProtectionInspecting, ClosedLidProtectionReleasing
{
  let identifier = "IOPM + pmset closed-lid protection"
  var isHeld: Bool { idleSleep.isHeld || closedLid.isHeld }
  // Closed-lid support is optional. Ordinary IOPM protection never requires
  // administrator setup and remains available when this component is absent.
  var requiresSetup: Bool { false }
  var isClosedLidEnabled: Bool {
    (closedLid as? any ClosedLidProtectionManaging)?.isClosedLidEnabled ?? true
  }
  var closedLidSetupState: PowerProtectSetupState {
    (closedLid as? any ClosedLidProtectionInspecting)?.closedLidSetupState ?? .unavailable
  }

  private let idleSleep: any SleepProtectionBackend
  private let closedLid: any SleepProtectionBackend

  init(
    idleSleep: any SleepProtectionBackend,
    closedLid: any SleepProtectionBackend,
    closedLidEnabled: Bool? = nil
  ) {
    self.idleSleep = idleSleep
    self.closedLid = closedLid
    if let closedLidEnabled {
      (closedLid as? any ClosedLidProtectionManaging)?.setClosedLidEnabled(closedLidEnabled)
    }
  }

  func prepare() throws {
    try prepareClosedLid()
  }

  func prepareClosedLid() throws {
    try closedLid.prepare()
  }

  func setClosedLidEnabled(_ enabled: Bool) {
    (closedLid as? any ClosedLidProtectionManaging)?.setClosedLidEnabled(enabled)
  }

  func recover() throws {
    var closedLidError: Error?
    do {
      try closedLid.recover()
    } catch {
      closedLidError = ClosedLidProtectionError.recoveryFailed
    }

    // Recovery of ordinary IOPM protection is independent. A stale or broken
    // optional closed-lid lease must never prevent this recovery path.
    try idleSleep.recover()
    if let closedLidError {
      throw closedLidError
    }
  }

  func acquire() throws {
    try idleSleep.acquire()
    guard isClosedLidEnabled else { return }
    do {
      try closedLid.acquire()
    } catch {
      throw Self.closedLidError(for: .acquisitionFailed, underlying: error)
    }
  }

  func renew() throws {
    if !idleSleep.isHeld {
      try idleSleep.acquire()
    } else {
      try idleSleep.renew()
    }

    if isClosedLidEnabled {
      do {
        if closedLid.isHeld {
          try closedLid.renew()
        } else {
          try closedLid.acquire()
        }
      } catch {
        throw Self.closedLidError(for: .renewalFailed, underlying: error)
      }
    } else if closedLid.isHeld {
      do {
        try closedLid.release()
      } catch {
        throw Self.closedLidError(for: .releaseFailed, underlying: error)
      }
    }
  }

  func release() throws {
    var firstError: Error?

    // Release the mandatory IOPM layer first. If the optional layer fails,
    // ordinary sleep protection still has a durable release path.
    do {
      try idleSleep.release()
    } catch {
      firstError = error
    }
    do {
      try closedLid.release()
    } catch {
      if firstError == nil {
        firstError = Self.closedLidError(for: .releaseFailed, underlying: error)
      }
    }
    if let firstError { throw firstError }
  }

  func releaseClosedLid() throws {
    do {
      try closedLid.release()
    } catch {
      throw Self.closedLidError(for: .releaseFailed, underlying: error)
    }
  }

  private enum ClosedLidOperation {
    case acquisitionFailed
    case renewalFailed
    case releaseFailed
  }

  private static func closedLidError(
    for operation: ClosedLidOperation,
    underlying: Error
  ) -> ClosedLidProtectionError {
    if (underlying as? PowerProtectError) == .setupRequired {
      return .setupRequired
    }
    switch operation {
    case .acquisitionFailed:
      return .acquisitionFailed
    case .renewalFailed:
      return .renewalFailed
    case .releaseFailed:
      return .releaseFailed
    }
  }
}
