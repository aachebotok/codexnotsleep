import Darwin
import Foundation
import MethamphetamineCore

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

struct PowerProtectCommandResult: Sendable {
  let status: Int32
  let output: String
}

protocol PowerProtectCommandRunning: Sendable {
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?
  ) throws -> PowerProtectCommandResult
}

extension PowerProtectCommandRunning {
  func run(executable: String, arguments: [String]) throws -> PowerProtectCommandResult {
    try run(executable: executable, arguments: arguments, environment: nil)
  }
}

struct ProcessPowerProtectCommandRunner: PowerProtectCommandRunning {
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?
  ) throws -> PowerProtectCommandResult {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    try process.run()
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return PowerProtectCommandResult(
      status: process.terminationStatus,
      output: String(decoding: outputData, as: UTF8.self)
    )
  }
}

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

@MainActor
protocol PowerProtectAuthorizationRunning: AnyObject {
  func run(script source: String) -> PowerProtectCommandResult
}

@MainActor
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

@MainActor
protocol PowerProtectInstalling: AnyObject {
  var isInstalled: Bool { get }
  func install() async throws
}

@MainActor
final class PowerProtectInstaller: PowerProtectInstalling {
  static let authorizationPrompt =
    "Allow Methamphetamine to keep your Mac running with the lid closed. You'll only need to confirm once."

  static var authorizationPreviewAppleScript: String {
    "do shell script \"/usr/bin/true\" with prompt \"\(authorizationPrompt)\" with administrator privileges"
  }

  var isInstalled: Bool {
    installationCheck() && Self.verifyInstallation(using: runner)
  }
  private let runner: any PowerProtectCommandRunning
  private let authorizationRunner: any PowerProtectAuthorizationRunning
  private let userID: uid_t
  private let sudoersPath: String
  private let installationCheck: () -> Bool

  init(
    runner: any PowerProtectCommandRunning = ProcessPowerProtectCommandRunner(),
    authorizationRunner: any PowerProtectAuthorizationRunning =
      NSAppleScriptPowerProtectAuthorizationRunner(),
    userID: uid_t = getuid(),
    fileManager: FileManager = .default,
    installationCheck: (() -> Bool)? = nil
  ) {
    self.runner = runner
    self.authorizationRunner = authorizationRunner
    self.userID = userID
    let sudoersPath = Self.sudoersPath(for: userID)
    self.sudoersPath = sudoersPath
    let check = installationCheck ?? {
      fileManager.fileExists(atPath: sudoersPath)
    }
    self.installationCheck = check
  }

  func install() async throws {
    if isInstalled { return }

    let result = authorizationRunner.run(script: administratorAppleScript)

    guard result.status == 0 else {
      if result.status == -128 {
        throw PowerProtectError.setupCancelled
      }
      throw PowerProtectError.setupFailed
    }
    guard installationCheck() else {
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
    "/private/etc/sudoers.d/methamphetamine_power_protect_\(userID)"
  }

  private nonisolated static func verifyInstallation(
    using runner: any PowerProtectCommandRunning
  ) -> Bool {
    for arguments in verificationArgumentSets {
      guard
        let result = try? runner.run(executable: "/usr/bin/sudo", arguments: arguments),
        result.status == 0
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

@MainActor
protocol PowerProtectWatchdogControlling: AnyObject {
  func start(parentPID: Int32, leaseURL: URL, token: String) throws
  func stop()
}

@MainActor
final class ProcessPowerProtectWatchdog: PowerProtectWatchdogControlling {
  private var process: Process?

  func start(parentPID: Int32, leaseURL: URL, token: String) throws {
    stop()

    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", Self.watchdogScript]
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "C",
      "LC_ALL": "C",
      "METH_PARENT_PID": String(parentPID),
      "METH_LEASE_PATH": leaseURL.path,
      "METH_LEASE_TOKEN": token,
    ]
    let readinessPipe = Pipe()
    process.standardOutput = readinessPipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      let readiness = readinessPipe.fileHandleForReading.readData(ofLength: 6)
      guard readiness == Data("ready\n".utf8), process.isRunning else {
        if process.isRunning { process.terminate() }
        throw PowerProtectError.watchdogFailed
      }
      self.process = process
    } catch {
      throw PowerProtectError.watchdogFailed
    }
  }

  func stop() {
    guard let process else { return }
    if process.isRunning { process.terminate() }
    self.process = nil
  }

  static let watchdogScript =
    """
    /usr/bin/printf 'ready\n'
    while /bin/kill -0 "$METH_PARENT_PID" 2>/dev/null; do
      /bin/sleep 1
    done
    while [ "$(/bin/cat "$METH_LEASE_PATH" 2>/dev/null)" = "$METH_LEASE_TOKEN" ]; do
      current=$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }')
      if [ "$current" = "0" ]; then
        /bin/rm -f "$METH_LEASE_PATH"
        exit 0
      fi
      /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
      current=$(/usr/bin/pmset -g 2>/dev/null | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }')
      if [ "$current" = "0" ]; then
        /bin/rm -f "$METH_LEASE_PATH"
        exit 0
      fi
      /bin/sleep 2
    done
    """
}

@MainActor
final class PowerProtectLeaseStore {
  let url: URL
  private let fileManager: FileManager

  init(url: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    if let url {
      self.url = url
    } else {
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
      self.url = applicationSupport
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

@MainActor
final class PMSetPowerProtectBackend: SleepProtectionBackend {
  let identifier = "pmset closed-lid protection"
  private(set) var isHeld: Bool

  var requiresSetup: Bool { !installer.isInstalled }

  private let installer: any PowerProtectInstalling
  private let runner: any PowerProtectCommandRunning
  private let leaseStore: PowerProtectLeaseStore
  private let watchdog: any PowerProtectWatchdogControlling
  private var inheritedDisabledSleep = false

  init(
    installer: (any PowerProtectInstalling)? = nil,
    runner: any PowerProtectCommandRunning = ProcessPowerProtectCommandRunner(),
    leaseStore: PowerProtectLeaseStore = PowerProtectLeaseStore(),
    watchdog: any PowerProtectWatchdogControlling = ProcessPowerProtectWatchdog()
  ) {
    self.runner = runner
    self.leaseStore = leaseStore
    self.watchdog = watchdog
    self.installer = installer ?? PowerProtectInstaller(runner: runner)
    isHeld = leaseStore.hasLease
  }

  func prepare() async throws {
    try await installer.install()
  }

  func recover() throws {
    guard leaseStore.hasLease else { return }
    try restoreSleep()
  }

  func acquire() throws {
    guard !isHeld else { return }
    guard !requiresSetup else { throw PowerProtectError.setupRequired }

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
      ]
    )
    guard result.status == 0 else {
      throw isDisabled ? PowerProtectError.commandFailed : PowerProtectError.restoreFailed
    }
  }

  private func sleepIsDisabled() throws -> Bool {
    let result = try runner.run(executable: "/usr/bin/pmset", arguments: ["-g"])
    guard result.status == 0 else { throw PowerProtectError.stateVerificationFailed }
    for line in result.output.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.first == "SleepDisabled", let value = fields.last {
        return value == "1"
      }
    }
    return false
  }
}

@MainActor
final class CombinedSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "IOPM + pmset closed-lid protection"
  var isHeld: Bool { idleSleep.isHeld || closedLid.isHeld }
  var requiresSetup: Bool { closedLid.requiresSetup }

  private let idleSleep: any SleepProtectionBackend
  private let closedLid: any SleepProtectionBackend

  init(
    idleSleep: any SleepProtectionBackend,
    closedLid: any SleepProtectionBackend
  ) {
    self.idleSleep = idleSleep
    self.closedLid = closedLid
  }

  func prepare() async throws {
    try await closedLid.prepare()
  }

  func recover() throws {
    try closedLid.recover()
    try idleSleep.recover()
  }

  func acquire() throws {
    try idleSleep.acquire()
    do {
      try closedLid.acquire()
    } catch {
      let activationError = error
      do {
        try idleSleep.release()
      } catch {
        throw error
      }
      throw activationError
    }
  }

  func renew() throws {
    let acquiredIdleSleep = !idleSleep.isHeld
    if acquiredIdleSleep {
      try idleSleep.acquire()
    } else {
      try idleSleep.renew()
    }

    do {
      if closedLid.isHeld {
        try closedLid.renew()
      } else {
        try closedLid.acquire()
      }
    } catch {
      let renewalError = error
      if acquiredIdleSleep {
        do {
          try idleSleep.release()
        } catch {
          throw error
        }
      }
      throw renewalError
    }
  }

  func release() throws {
    var firstError: Error?
    do {
      try closedLid.release()
    } catch {
      firstError = error
    }
    do {
      try idleSleep.release()
    } catch {
      if firstError == nil { firstError = error }
    }
    if let firstError { throw firstError }
  }
}
