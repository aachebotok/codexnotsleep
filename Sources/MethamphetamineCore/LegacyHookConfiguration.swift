import Foundation

public enum IntegrationKind: String, CaseIterable, Sendable {
  case codex
  case claude
}

public enum IntegrationConfigurationPaths {
  public static func url(for integration: IntegrationKind, homeDirectory: URL) -> URL {
    switch integration {
    case .codex:
      homeDirectory.appending(path: ".codex/hooks.json")
    case .claude:
      homeDirectory.appending(path: ".claude/settings.json")
    }
  }
}

public enum LegacyHookConfigurationError: Error {
  case rootNotObject
}

public enum LegacyHookConfiguration {
  public static let marker = "methamphetamine-hook"

  public static func removing(data: Data, integration: IntegrationKind) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LegacyHookConfigurationError.rootNotObject
    }
    guard var hooks = root["hooks"] as? [String: Any] else { return data }
    let providerArgument = "--provider \(integration.rawValue)"

    for event in Array(hooks.keys) {
      guard let groups = hooks[event] as? [[String: Any]] else { continue }
      let remainingGroups = groups.compactMap { group -> [String: Any]? in
        guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
        let remainingHandlers = handlers.filter { handler in
          let belongsToMethamphetamine = isLegacyHandler(
            handler,
            providerArgument: providerArgument
          )
          return !belongsToMethamphetamine
        }
        guard !remainingHandlers.isEmpty else { return nil }

        var updatedGroup = group
        updatedGroup["hooks"] = remainingHandlers
        return updatedGroup
      }

      if remainingGroups.isEmpty {
        hooks.removeValue(forKey: event)
      } else {
        hooks[event] = remainingGroups
      }
    }

    if hooks.isEmpty {
      root.removeValue(forKey: "hooks")
    } else {
      root["hooks"] = hooks
    }
    return try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
  }

  public static func containsIntegration(data: Data?, integration: IntegrationKind) -> Bool {
    guard let data,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let hooks = root["hooks"] as? [String: Any]
    else { return false }
    let providerArgument = "--provider \(integration.rawValue)"

    return hooks.values.contains { value in
      guard let groups = value as? [[String: Any]] else { return false }
      return groups.contains { group in
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains { handler in
          isLegacyHandler(handler, providerArgument: providerArgument)
        }
      }
    }
  }

  private static func isLegacyHandler(
    _ handler: [String: Any],
    providerArgument: String
  ) -> Bool {
    guard handler["statusMessage"] as? String == marker,
      let command = handler["command"] as? String
    else { return false }

    let tokens = command.split(whereSeparator: \Character.isWhitespace).map(String.init)
    let providerTokens = providerArgument.split(separator: " ").map(String.init)
    let hasExactProvider = tokens.indices.contains { index in
      guard index + 1 < tokens.endIndex else { return false }
      return tokens[index] == providerTokens[0] && tokens[index + 1] == providerTokens[1]
    }

    return command.contains("/Contents/Helpers/meth-hook")
      && hasExactProvider
  }
}
