import SwiftUI

struct MenuContentView: View {
  @ObservedObject var controller: AppController

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Toggle(
          isOn: Binding(
            get: { controller.isProtectionEnabled },
            set: { controller.setProtectionEnabled($0) }
          )
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Не спать")
              .font(.system(size: 15))
            Text("Пока работает Codex")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .disabled(controller.isPreparingProtection)
        .accessibilityHint("Mac не засыпает во время активной задачи Codex")

        Divider()
          .padding(.top, 8)
          .padding(.bottom, 6)

        Button("Выйти") {
          NSApplication.shared.terminate(nil)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .accessibilityHint("Закрывает Methamphetamine и возвращает обычный режим сна")
      }

      if let error = controller.visibleError {
        Divider()
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Ошибка: \(error)")
      }
    }
    .frame(width: 288, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.top, 14)
    .padding(.bottom, 12)
    .onAppear(perform: controller.menuDidOpen)
  }
}
