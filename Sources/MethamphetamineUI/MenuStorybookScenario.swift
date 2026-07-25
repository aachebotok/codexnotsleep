@MainActor
struct MenuStorybookScenario: Identifiable {
  let id: String
  let title: String
  let note: String
  let state: MenuContentState

  static let all: [MenuStorybookScenario] = [
    .init(
      id: "disabled",
      title: "Выключено",
      note: "Mac спит как обычно",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "waiting",
      title: "Ожидание",
      note: "Защита включена, задач нет",
      state: .init(
        isProtectionEnabled: true,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "protected",
      title: "Codex работает",
      note: "Mac защищён от сна",
      state: .init(
        isProtectionEnabled: true,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "grace",
      title: "Задача завершилась",
      note: "Короткая пауза перед возвратом сна",
      state: .init(
        isProtectionEnabled: true,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "low-battery",
      title: "Низкий заряд",
      note: "При 10% и ниже Mac может уснуть",
      state: .init(
        isProtectionEnabled: true,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "preparing",
      title: "Настройка",
      note: "Ожидание системного подтверждения",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: true,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "permission",
      title: "Нужно разрешение",
      note: "Чтобы Mac работал с закрытой крышкой",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: false,
        issue: .permissionRequired,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "restore",
      title: "Сон не включился",
      note: "Mac не засыпает после завершения задачи",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: false,
        issue: .sleepRestoreRequired,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "restoring",
      title: "Возврат сна",
      note: "Приложение возвращает обычный режим сна",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: false,
        issue: .sleepRestoreRequired,
        isResolvingIssue: true
      )
    ),
  ]
}
