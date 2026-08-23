import Foundation

enum MenuIssue: Equatable {
  case permissionRequired
  case sleepRestoreRequired
  case closedLidRecoveryRequired

  var title: String {
    switch self {
    case .permissionRequired:
      "Set Up Closed-Lid Protection…"
    case .sleepRestoreRequired:
      "Fix sleep issue"
    case .closedLidRecoveryRequired:
      "Fix closed-lid sleep issue"
    }
  }
}
