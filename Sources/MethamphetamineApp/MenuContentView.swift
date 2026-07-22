import SwiftUI

struct MenuContentView: View {
  @ObservedObject var controller: AppController

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(
        isOn: Binding(
          get: { controller.isProtectionEnabled },
          set: { controller.setProtectionEnabled($0) }
        )
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Не спать")
          Text("Пока работают агенты")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .toggleStyle(.switch)
      .disabled(controller.isPreparingProtection)
      .accessibilityHint("Учитываются все поддерживаемые агенты")

      Toggle(
        isOn: Binding(
          get: { controller.isLowBatterySleepEnabled },
          set: { controller.setLowBatterySleepEnabled($0) }
        )
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Экономить заряд")
          Text("Разрешать сон при заряде ниже 10%")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .toggleStyle(.switch)

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
