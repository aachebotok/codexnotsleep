import SwiftUI

public enum MenuIssue: Equatable, Identifiable {
  case permissionRequired
  case sleepRestoreRequired

  public var id: Self { self }

  public var title: String {
    switch self {
    case .permissionRequired:
      "Работа с закрытой крышкой"
    case .sleepRestoreRequired:
      "Исправить сбой сна"
    }
  }

  var message: String {
    switch self {
    case .permissionRequired:
      "Нужен пароль администратора"
    case .sleepRestoreRequired:
      "Чтобы Mac снова нормально засыпал"
    }
  }
}
