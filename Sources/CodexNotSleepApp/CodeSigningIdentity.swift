import Foundation
import Security

enum CodeSigningIdentity {
  static func teamIdentifier(at executableURL: URL) -> String? {
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return nil }

    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let dictionary = information as? [String: Any]
    else { return nil }

    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
  }
}
