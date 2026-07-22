import Darwin
import Foundation
import MethamphetamineCore

struct ProcessInvocation: Equatable, Sendable {
  let executablePath: String
  let arguments: [String]
}

struct BSDProcessReader {
  private static let maximumArgumentBytes: Int = {
    var value: Int32 = 0
    var valueSize = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.argmax", &value, &valueSize, nil, 0) == 0, value > 0 else {
      return 1_048_576
    }
    return Int(value)
  }()

  private let userID: uid_t

  init(userID: uid_t = getuid()) {
    self.userID = userID
  }

  /// Returns nil only when the process inventory could not be read reliably.
  /// Callers can then keep the last successful runtime snapshot instead of
  /// incorrectly deciding that every agent stopped.
  func observations(
    for definitions: [CodingAgentDefinition],
    installedExecutables: [InstalledExecutable]
  ) -> [CodingAgentProcessObservation]? {
    guard let processes = processTable() else { return nil }

    var result: [CodingAgentProcessObservation] = []
    var candidateReadFailed = false

    for process in processes {
      guard process.kp_eproc.e_pcred.p_ruid == userID,
        process.kp_proc.p_stat != SZOMB,
        process.kp_eproc.e_tdev != dev_t(-1)
      else { continue }

      let name = processName(process)
      let isKnownNativeName = installedExecutables.contains { $0.name == name }
      guard isKnownNativeName || isInterpreter(name) else { continue }

      guard let invocation = processInvocation(processID: process.kp_proc.p_pid) else {
        candidateReadFailed = true
        continue
      }

      result.append(
        contentsOf: observations(
          processName: name,
          invocation: invocation,
          definitions: definitions,
          installedExecutables: installedExecutables
        )
      )
    }

    return candidateReadFailed ? nil : result
  }

  func observations(
    processName: String,
    invocation: ProcessInvocation,
    definitions: [CodingAgentDefinition],
    installedExecutables: [InstalledExecutable]
  ) -> [CodingAgentProcessObservation] {
    let interpreter = isInterpreter(processName)
    let processPaths = matchingPaths(for: invocation, includeScriptArguments: interpreter)

    return installedExecutables.compactMap { executable in
      guard !processPaths.isDisjoint(with: executable.matchingPaths),
        let definition = definitions.first(where: { $0.executableNames.contains(executable.name) })
      else { return nil }

      let inspectedArguments = invocation.arguments.dropFirst().prefix(8)
      let isExcludedHelper = inspectedArguments.contains { argument in
        definition.excludedFirstArguments.contains(argument)
      }

      return CodingAgentProcessObservation(
        executableName: executable.name,
        hasControllingTerminal: true,
        isExcludedHelper: isExcludedHelper
      )
    }
  }

  private func processTable() -> [kinfo_proc]? {
    var managementInformationBase = [Int32(CTL_KERN), KERN_PROC, KERN_PROC_ALL, 0]
    var requiredSize = 0

    guard
      sysctl(
        &managementInformationBase,
        u_int(managementInformationBase.count),
        nil,
        &requiredSize,
        nil,
        0
      ) == 0
    else { return nil }

    let stride = MemoryLayout<kinfo_proc>.stride
    var capacity = max(requiredSize / stride + 16, 16)

    for _ in 0..<3 {
      var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
      var bufferSize = processes.count * stride
      let result = processes.withUnsafeMutableBytes { buffer in
        sysctl(
          &managementInformationBase,
          u_int(managementInformationBase.count),
          buffer.baseAddress,
          &bufferSize,
          nil,
          0
        )
      }

      if result == 0 {
        return Array(processes.prefix(bufferSize / stride))
      }
      guard errno == ENOMEM else { return nil }
      capacity *= 2
    }

    return nil
  }

  private func processName(_ process: kinfo_proc) -> String {
    withUnsafePointer(to: process.kp_proc.p_comm) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
        String(cString: $0)
      }
    }
  }

  private func processInvocation(processID: pid_t) -> ProcessInvocation? {
    var buffer = [UInt8](repeating: 0, count: Self.maximumArgumentBytes)
    var bufferSize = buffer.count
    var managementInformationBase = [Int32(CTL_KERN), KERN_PROCARGS2, processID]
    let result = buffer.withUnsafeMutableBytes { bytes in
      sysctl(
        &managementInformationBase,
        u_int(managementInformationBase.count),
        bytes.baseAddress,
        &bufferSize,
        nil,
        0
      )
    }
    guard result == 0 else { return nil }
    return Self.parseInvocation(buffer: buffer, count: bufferSize)
  }

  static func parseInvocation(buffer: [UInt8], count: Int) -> ProcessInvocation? {
    let integerSize = MemoryLayout<Int32>.size
    guard count >= integerSize, count <= buffer.count else { return nil }

    var argumentCount: Int32 = 0
    withUnsafeMutableBytes(of: &argumentCount) { destination in
      destination.copyBytes(from: buffer.prefix(integerSize))
    }
    guard argumentCount > 0, argumentCount < 4_096 else { return nil }

    var index = integerSize
    guard let executablePath = readString(in: buffer, index: &index, limit: count) else {
      return nil
    }
    skipNullBytes(in: buffer, index: &index, limit: count)

    var arguments: [String] = []
    arguments.reserveCapacity(Int(argumentCount))
    for _ in 0..<argumentCount {
      guard let argument = readString(in: buffer, index: &index, limit: count) else {
        return nil
      }
      arguments.append(argument)
      skipNullBytes(in: buffer, index: &index, limit: count)
    }

    return ProcessInvocation(executablePath: executablePath, arguments: arguments)
  }

  private func matchingPaths(
    for invocation: ProcessInvocation,
    includeScriptArguments: Bool
  ) -> Set<String> {
    var paths = canonicalVariants(for: invocation.executablePath)
    guard includeScriptArguments else { return paths }

    for argument in invocation.arguments.prefix(8) where argument.hasPrefix("/") {
      paths.formUnion(canonicalVariants(for: argument))
    }
    return paths
  }

  private func canonicalVariants(for path: String) -> Set<String> {
    guard path.hasPrefix("/") else { return [] }
    let url = URL(fileURLWithPath: path)
    return [
      InstalledExecutable.canonicalPath(url.path),
      InstalledExecutable.canonicalPath(url.resolvingSymlinksInPath().path),
    ]
  }

  private func isInterpreter(_ processName: String) -> Bool {
    let normalized = processName.lowercased()
    return normalized == "node"
      || normalized == "bun"
      || normalized == "deno"
      || normalized == "ruby"
      || normalized.hasPrefix("python")
  }

  private static func skipNullBytes(in buffer: [UInt8], index: inout Int, limit: Int) {
    while index < limit, buffer[index] == 0 {
      index += 1
    }
  }

  private static func readString(
    in buffer: [UInt8],
    index: inout Int,
    limit: Int
  ) -> String? {
    guard index < limit else { return nil }
    let start = index
    while index < limit, buffer[index] != 0 {
      index += 1
    }
    guard start < index else { return nil }
    return String(bytes: buffer[start..<index], encoding: .utf8)
  }
}
