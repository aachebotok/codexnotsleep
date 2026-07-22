import Foundation
import MethamphetamineCore
import Testing

@testable import MethamphetamineApp

@Suite
struct BSDProcessReaderTests {
  private let reader = BSDProcessReader(userID: 501)

  @Test
  func matchesNodeAndPythonAgentsByInstalledScriptPath() {
    let definitions = CodingAgentCatalog.supported
    let geminiScript = "/usr/local/lib/node_modules/@google/gemini-cli/bundle/gemini.js"
    let aiderScript = "/opt/homebrew/bin/aider"
    let installations = [
      InstalledExecutable(name: "gemini", matchingPaths: [geminiScript]),
      InstalledExecutable(name: "aider", matchingPaths: [aiderScript]),
    ]

    let gemini = reader.observations(
      processName: "node",
      invocation: ProcessInvocation(
        executablePath: "/opt/homebrew/bin/node",
        arguments: ["node", geminiScript]
      ),
      definitions: definitions,
      installedExecutables: installations
    )
    let aider = reader.observations(
      processName: "Python",
      invocation: ProcessInvocation(
        executablePath: "/opt/homebrew/bin/python3",
        arguments: ["python3", aiderScript]
      ),
      definitions: definitions,
      installedExecutables: installations
    )

    #expect(gemini.map(\.executableName) == ["gemini"])
    #expect(aider.map(\.executableName) == ["aider"])
  }

  @Test
  func rejectsSameNameNativeProcessFromAnotherPath() {
    let installation = InstalledExecutable(
      name: "codex",
      matchingPaths: ["/usr/local/bin/codex"]
    )

    let observations = reader.observations(
      processName: "codex",
      invocation: ProcessInvocation(
        executablePath: "/tmp/project/codex",
        arguments: ["/tmp/project/codex"]
      ),
      definitions: CodingAgentCatalog.supported,
      installedExecutables: [installation]
    )

    #expect(observations.isEmpty)
  }

  @Test
  func excludesCodexHelperSubcommandAfterGlobalOptions() throws {
    let codexPath = "/usr/local/bin/codex"
    let installation = InstalledExecutable(name: "codex", matchingPaths: [codexPath])

    let observations = reader.observations(
      processName: "codex",
      invocation: ProcessInvocation(
        executablePath: codexPath,
        arguments: [codexPath, "-c", "feature=true", "app-server", "--listen", "stdio://"]
      ),
      definitions: CodingAgentCatalog.supported,
      installedExecutables: [installation]
    )

    let observation = try #require(observations.first)
    #expect(observation.isExcludedHelper)
  }

  @Test
  func invocationParserStopsAfterArgcBeforeEnvironment() throws {
    var argumentCount: Int32 = 2
    var buffer = withUnsafeBytes(of: &argumentCount) { Array($0) }
    buffer.append(contentsOf: "/usr/bin/node\0node\0/script/gemini.js\0SECRET=value\0".utf8)

    let invocation = try #require(
      BSDProcessReader.parseInvocation(buffer: buffer, count: buffer.count))

    #expect(invocation.executablePath == "/usr/bin/node")
    #expect(invocation.arguments == ["node", "/script/gemini.js"])
  }
}
