import Foundation
import Security
import LocalAuthentication

let account = "touchenv"

/// Prompt Touch ID and block until the user authenticates or cancels.
func requireTouchID(reason: String) {
    let context = LAContext()
    var error: NSError?

    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
        fputs("Error: Touch ID not available: \(error?.localizedDescription ?? "unknown")\n", stderr)
        exit(1)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var authError: Error?

    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, err in
        if !success {
            authError = err
        }
        semaphore.signal()
    }

    semaphore.wait()

    if let err = authError {
        fputs("Error: Touch ID authentication failed: \(err.localizedDescription)\n", stderr)
        exit(1)
    }
}

func store(service: String) {
    let data: Data

    if isatty(STDIN_FILENO) != 0 {
        // Interactive terminal — prompt for input (hidden, like a password)
        guard let value = getpass("Enter value for '\(service)': ") else {
            fputs("Error: no input provided\n", stderr)
            exit(1)
        }
        guard let d = String(cString: value).data(using: .utf8), !d.isEmpty else {
            fputs("Error: no input provided\n", stderr)
            exit(1)
        }
        data = d
    } else {
        // Piped input
        guard let d = FileHandle.standardInput.readDataToEndOfFile().nilIfEmpty else {
            fputs("Error: no input provided on stdin\n", stderr)
            exit(1)
        }
        data = d
    }

    // Trim trailing newline
    let trimmed = data.withUnsafeBytes { buf -> Data in
        var end = buf.count
        while end > 0 && (buf[end - 1] == 0x0A || buf[end - 1] == 0x0D) {
            end -= 1
        }
        return Data(buf[0..<end])
    }

    // Delete any existing item first
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: trimmed,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status != errSecSuccess {
        fputs("Error: failed to store item: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)\n", stderr)
        exit(1)
    }

    fputs("Stored '\(service)' in Keychain (Touch ID protected)\n", stderr)
}

func getValue(service: String) -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound {
        fputs("Error: '\(service)' not found in Keychain\n", stderr)
        fputs("  Run: touchenv store \(service)\n", stderr)
        exit(1)
    }

    if status != errSecSuccess {
        fputs("Error: failed to retrieve item: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)\n", stderr)
        exit(1)
    }

    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
        fputs("Error: failed to decode item data\n", stderr)
        exit(1)
    }

    return value
}

func get(service: String) {
    requireTouchID(reason: "Access secret '\(service)' from Keychain")
    print(getValue(service: service), terminator: "")
}

func delete(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]

    let status = SecItemDelete(query as CFDictionary)

    if status == errSecItemNotFound {
        fputs("Error: '\(service)' not found in Keychain\n", stderr)
        exit(1)
    }

    if status != errSecSuccess {
        fputs("Error: failed to delete item: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)\n", stderr)
        exit(1)
    }

    fputs("Deleted '\(service)' from Keychain\n", stderr)
}

func list() {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound {
        return
    }

    if status != errSecSuccess {
        fputs("Error: failed to list items: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)\n", stderr)
        exit(1)
    }

    guard let items = result as? [[String: Any]] else {
        return
    }

    for item in items {
        if let service = item[kSecAttrService as String] as? String {
            print(service)
        }
    }
}

func exec(envFile: String, command: [String]) {
    // Read and parse .env file
    let contents: String
    do {
        contents = try String(contentsOfFile: envFile, encoding: .utf8)
    } catch {
        fputs("Error: cannot read '\(envFile)': \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    var env = ProcessInfo.processInfo.environment
    var keychainKeys: [String] = []

    // First pass: find which keys need keychain lookup
    for line in contents.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[trimmed.startIndex..<eqIndex])
        let value = String(trimmed[trimmed.index(after: eqIndex)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        if value.hasPrefix("touchenv:") {
            keychainKeys.append(String(value.dropFirst("touchenv:".count)))
        }

        env[key] = value
    }

    // Single Touch ID prompt for all keychain values
    if !keychainKeys.isEmpty {
        requireTouchID(reason: "Unlock \(keychainKeys.count) secret\(keychainKeys.count == 1 ? "" : "s")")

        // Resolve keychain values
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
            let value = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if value.hasPrefix("touchenv:") {
                let keychainKey = String(value.dropFirst("touchenv:".count))
                env[key] = getValue(service: keychainKey)
            }
        }
    }

    if command.isEmpty {
        fputs("Error: no command specified after --\n", stderr)
        exit(1)
    }

    // Execute the command with resolved environment
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = command
    task.environment = env

    do {
        try task.run()
        task.waitUntilExit()
        exit(task.terminationStatus)
    } catch {
        fputs("Error: failed to run command: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func usage() {
    fputs("""
    Usage: touchenv <command> [args]

    Commands:
      store <key>                Store a secret (interactive prompt or pipe)
      get <key>                  Retrieve a secret (Touch ID) -> stdout
      delete <key>               Remove from Keychain
      list                       List stored keys
      exec <envfile> -- <cmd>    Load .env, resolve touchenv: values, run cmd

    In .env files, use touchenv:<key> as a value to pull from Keychain:
      NODE_KEY=touchenv:MYAPP_NODE_STAGING_KEY

    Examples:
      touchenv store MY_KEY
      touchenv get MY_KEY
      touchenv exec .env.staging -- bin/deploy_backend.sh staging

    """, stderr)
}

// MARK: - Helpers

extension Data {
    var nilIfEmpty: Data? {
        isEmpty ? nil : self
    }
}

// MARK: - Main

@main
struct TouchEnv {
    static func main() {
        let args = CommandLine.arguments.dropFirst()

        guard let command = args.first else {
            usage()
            exit(1)
        }

        switch command {
        case "store":
            guard args.count == 2, let key = args.dropFirst().first else {
                fputs("Usage: touchenv store <key>\n", stderr)
                exit(1)
            }
            store(service: key)

        case "get":
            guard args.count == 2, let key = args.dropFirst().first else {
                fputs("Usage: touchenv get <key>\n", stderr)
                exit(1)
            }
            get(service: key)

        case "delete":
            guard args.count == 2, let key = args.dropFirst().first else {
                fputs("Usage: touchenv delete <key>\n", stderr)
                exit(1)
            }
            delete(service: key)

        case "list":
            list()

        case "exec":
            let remaining = Array(args.dropFirst())
            if let dashIndex = remaining.firstIndex(of: "--") {
                guard dashIndex == 1 else {
                    fputs("Usage: touchenv exec <envfile> -- <command...>\n", stderr)
                    exit(1)
                }
                let envFile = remaining[0]
                let cmd = Array(remaining[(dashIndex + 1)...])
                exec(envFile: envFile, command: cmd)
            } else {
                fputs("Usage: touchenv exec <envfile> -- <command...>\n", stderr)
                exit(1)
            }

        default:
            fputs("Unknown command: \(command)\n", stderr)
            usage()
            exit(1)
        }
    }
}
