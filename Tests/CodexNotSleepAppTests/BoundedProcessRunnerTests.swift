import Darwin
import Foundation
import Testing

@testable import CodexNotSleepApp

@Suite
struct BoundedProcessRunnerTests {
  @Test
  func capturesSuccessfulOutputAndExitStatus() throws {
    let result = try BoundedProcessRunner(timeout: 2).run(
      executable: "/bin/sh",
      arguments: ["-c", "printf out; printf err >&2"]
    )

    #expect(result.succeeded)
    #expect(result.status == 0)
    #expect(result.stdout == "out")
    #expect(result.stderr == "err")
  }

  @Test
  func reportsNonZeroExit() throws {
    let result = try BoundedProcessRunner(timeout: 2).run(
      executable: "/bin/sh",
      arguments: ["-c", "exit 7"]
    )

    #expect(!result.succeeded)
    #expect(result.status == 7)
    #expect(!result.didTimeout)
  }

  @Test
  func terminatesTimedOutChild() throws {
    let result = try BoundedProcessRunner(
      timeout: 0.05,
      terminationGrace: 0.05
    ).run(
      executable: "/bin/sh",
      arguments: ["-c", "sleep 2"]
    )

    #expect(result.didTimeout)
    #expect(!result.succeeded)
    #expect(result.status != nil)
  }

  @Test
  func timeoutTerminatesDescendantsInTheOwnedProcessGroup() throws {
    let marker = FileManager.default.temporaryDirectory.appending(
      path: "CodexNotSleep.BoundedProcessRunner.\(UUID().uuidString).pid"
    )
    defer { try? FileManager.default.removeItem(at: marker) }

    let result = try BoundedProcessRunner(
      timeout: 0.1,
      terminationGrace: 0.1
    ).run(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "sleep 30 & child=$!; printf '%s' \"$child\" > \"\(marker.path)\"; wait",
      ]
    )

    #expect(result.didTimeout)
    let childPID = try #require(
      Int32(String(decoding: try Data(contentsOf: marker), as: UTF8.self))
    )
    var childStillExists = true
    for _ in 0..<30 where childStillExists {
      childStillExists = kill(childPID, 0) == 0
      if childStillExists { usleep(10_000) }
    }
    #expect(!childStillExists)
  }

  @Test
  func boundsEachOutputStream() throws {
    let result = try BoundedProcessRunner(
      timeout: 2,
      maximumOutputBytes: 128
    ).run(
      executable: "/bin/sh",
      arguments: [
        "-c",
        "i=0; while [ $i -lt 10000 ]; do printf x; printf y >&2; i=$((i+1)); done",
      ]
    )

    #expect(result.succeeded)
    #expect(result.stdout.utf8.count == 128)
    #expect(result.stderr.utf8.count == 128)
  }

  @Test
  func reportsLaunchFailureAndRejectsRelativePaths() throws {
    let missing = try BoundedProcessRunner(timeout: 1).run(
      executable: "/definitely/missing/codex-not-sleep-command",
      arguments: []
    )
    #expect(missing.status == nil)
    #expect(missing.launchError != nil)

    let relative = try BoundedProcessRunner(timeout: 1).run(
      executable: "sh",
      arguments: []
    )
    #expect(relative.status == nil)
    #expect(relative.launchError == "Executable path must be absolute")
  }
}
