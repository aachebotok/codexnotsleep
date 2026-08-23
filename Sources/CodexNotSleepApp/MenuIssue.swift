import Foundation

enum MenuIssue: Equatable, Sendable {
  case permissionRequired
  case sleepRestoreRequired
  case closedLidSetupRepairRequired
  case closedLidRecoveryRequired

  var title: String {
    switch self {
    case .permissionRequired:
      "Set Up Closed-Lid Protection…"
    case .sleepRestoreRequired:
      "Fix sleep issue"
    case .closedLidSetupRepairRequired:
      "Repair Lid-Closed Support…"
    case .closedLidRecoveryRequired:
      "Fix closed-lid sleep issue"
    }
  }
}
