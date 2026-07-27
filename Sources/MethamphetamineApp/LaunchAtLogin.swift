import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
  var status: LaunchAtLoginStatus { get }
  func register() throws
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
  private let service = SMAppService.mainApp

  var status: LaunchAtLoginStatus {
    switch service.status {
    case .notRegistered:
      .notRegistered
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .notFound
    @unknown default:
      .notFound
    }
  }

  func register() throws {
    try service.register()
  }
}

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
  func enableByDefault() -> String?
}

@MainActor
final class LaunchAtLoginController: LaunchAtLoginControlling {
  static let failureMessage = "Couldn't enable launch at login"

  private let service: any LaunchAtLoginServicing
  private let canRegisterCurrentApp: () -> Bool

  init(
    service: any LaunchAtLoginServicing = SystemLaunchAtLoginService(),
    canRegisterCurrentApp: @escaping () -> Bool = LaunchAtLoginController.canRegisterCurrentApp
  ) {
    self.service = service
    self.canRegisterCurrentApp = canRegisterCurrentApp
  }

  func enableByDefault() -> String? {
    guard canRegisterCurrentApp() else {
      NSLog("Methamphetamine skipped launch-at-login registration outside a writable app bundle")
      return nil
    }

    switch service.status {
    case .enabled:
      NSLog("Methamphetamine launch at login is already enabled")
      return nil
    case .requiresApproval:
      NSLog("Methamphetamine launch at login requires user approval")
      return nil
    case .notRegistered, .notFound:
      break
    }

    do {
      try service.register()
    } catch {
      NSLog(
        "Methamphetamine failed to register launch at login (%@): %@",
        String(describing: service.status),
        error.localizedDescription
      )
      switch service.status {
      case .enabled, .requiresApproval:
        return nil
      case .notRegistered, .notFound:
        return Self.failureMessage
      }
    }

    switch service.status {
    case .enabled:
      NSLog("Methamphetamine enabled launch at login")
      return nil
    case .requiresApproval:
      NSLog("Methamphetamine launch at login requires user approval")
      return nil
    case .notRegistered, .notFound:
      NSLog(
        "Methamphetamine launch-at-login registration finished with status %@",
        String(describing: service.status)
      )
      return Self.failureMessage
    }
  }

  nonisolated private static func canRegisterCurrentApp() -> Bool {
    let bundleURL = Bundle.main.bundleURL
    guard bundleURL.pathExtension == "app" else { return false }

    guard
      let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
      let isReadOnly = values.volumeIsReadOnly
    else { return false }
    return !isReadOnly
  }
}

@MainActor
final class NoOpLaunchAtLoginController: LaunchAtLoginControlling {
  func enableByDefault() -> String? { nil }
}
