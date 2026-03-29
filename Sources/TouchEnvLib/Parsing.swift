import Foundation

/// A parsed key-value entry from a .env file.
public struct EnvEntry: Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Parse a .env file into an array of entries, skipping comments and blank lines.
/// Supports `export KEY=VALUE` syntax and matching quote stripping.
public func parseEnvFile(_ contents: String) -> [EnvEntry] {
    var entries: [EnvEntry] = []
    for line in contents.components(separatedBy: .newlines) {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        if trimmed.hasPrefix("export ") {
            trimmed = String(trimmed.dropFirst("export ".count))
                .trimmingCharacters(in: .whitespaces)
        }

        guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[trimmed.startIndex..<eqIndex])
        let rawValue = String(trimmed[trimmed.index(after: eqIndex)...])
        let value = stripMatchingQuotes(rawValue)

        entries.append(EnvEntry(key: key, value: value))
    }
    return entries
}

/// Strip surrounding quotes only if they match (both double or both single).
public func stripMatchingQuotes(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    let first = value.first!
    let last = value.last!
    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        return String(value.dropFirst().dropLast())
    }
    return value
}

public enum KeyValidationError: Error, Equatable {
    case empty
    case containsNull
}

/// Validate a keychain key name. Returns nil if valid, or an error describing the problem.
public func validateKeychainKey(_ key: String) -> KeyValidationError? {
    if key.isEmpty { return .empty }
    if key.contains("\0") { return .containsNull }
    return nil
}
