import SwiftUI

public enum MenuIssue: Equatable, Identifiable {
  case permissionRequired
  case sleepRestoreRequired

  public var id: Self { self }

  public var title: String {
    switch self {
    case .permissionRequired:
      "Use with lid closed"
    case .sleepRestoreRequired:
      "Fix sleep issue"
    }
  }

  var message: String {
    switch self {
    case .permissionRequired:
      "Administrator password required"
    case .sleepRestoreRequired:
      "So your Mac can sleep normally again"
    }
  }
}
