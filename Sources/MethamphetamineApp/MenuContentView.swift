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
            Text("Не засыпать")
            Text("Пока работает Codex")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .disabled(controller.isPreparingProtection)
        .accessibilityHint("Mac не засыпает во время активной задачи Codex")

        Divider()
          .padding(.top, 8)

        Text("Mac сможет уснуть при заряде 10% и ниже")
          .font(.caption)
          .foregroundStyle(.secondary)
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
    .padding(14)
    .onAppear(perform: controller.menuDidOpen)
  }
}
