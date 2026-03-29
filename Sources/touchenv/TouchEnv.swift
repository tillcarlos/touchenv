import Foundation
import Security
import LocalAuthentication
import TouchEnvLib

let account = "touchenv"
let appVersion = "1.1.0"

// MARK: - Helpers

func fatal(_ message: String) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(1)
}

func checkedKey(_ key: String) -> String {
    if let error = validateKeychainKey(key) {
        switch error {
        case .empty: fatal("keychain key name cannot be empty")
        case .containsNull: fatal("keychain key name contains invalid characters")
        }
    }
    return key
}

func baseQuery(service: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
}

func requireSingleArg(_ args: ArraySlice<String>, usage: String) -> String {
    guard args.count == 2, let key = args.dropFirst().first else {
        fputs("Usage: touchenv \(usage)\n", stderr)
        exit(1)
    }
    return checkedKey(key)
}

extension Data {
    var nilIfEmpty: Data? {
        isEmpty ? nil : self
    }
}

/// Get the name of the parent process that invoked touchenv.
func parentProcessName() -> String? {
    let ppid = getppid()
    guard ppid > 0 else { return nil }
    let proc = ProcessInfo.processInfo
    // Use ps to get the parent's command — works reliably on macOS
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", "\(ppid)", "-o", "command="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            return output
        }
    } catch {}
    return nil
}

// MARK: - Touch ID

/// Prompt Touch ID and block until the user authenticates or cancels.
/// Returns the authenticated LAContext so it can be reused for Keychain access.
func requireTouchID(reason: String) -> LAContext {
    let context = LAContext()
    var error: NSError?

    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
        fatal("Touch ID not available: \(error?.localizedDescription ?? "unknown")")
    }

    var fullReason = reason
    if let caller = parentProcessName() {
        fullReason += "\ncaller: \(caller)"
    }

    let semaphore = DispatchSemaphore(value: 0)
    var authError: Error?

    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: fullReason) { success, err in
        if !success { authError = err }
        semaphore.signal()
    }

    semaphore.wait()

    if let err = authError {
        fatal("Touch ID authentication failed: \(err.localizedDescription)")
    }

    return context
}

// MARK: - Input

/// Read a secret from stdin, with echo disabled for interactive terminals.
/// No length limit (unlike the deprecated getpass which truncates at 128 bytes).
func readSecretFromStdin() -> Data {
    if isatty(STDIN_FILENO) != 0 {
        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)

        var newTermios = oldTermios
        newTermios.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

        fputs("Enter secret value: ", stderr)
        let line = readLine(strippingNewline: true)

        tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
        fputs("\n", stderr)

        guard let input = line, !input.isEmpty,
              let data = input.data(using: .utf8) else {
            fatal("no input provided")
        }
        return data
    } else {
        guard let data = FileHandle.standardInput.readDataToEndOfFile().nilIfEmpty else {
            fatal("no input provided on stdin")
        }
        return data.withUnsafeBytes { buf -> Data in
            var end = buf.count
            while end > 0 && (buf[end - 1] == 0x0A || buf[end - 1] == 0x0D) {
                end -= 1
            }
            return Data(buf[0..<end])
        }
    }
}

// MARK: - Commands

func store(service: String) {
    let _ = requireTouchID(reason: "-> touchenv store \(service)")
    let data = readSecretFromStdin()

    SecItemDelete(baseQuery(service: service) as CFDictionary)

    var accessError: Unmanaged<CFError>?
    guard let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet,
        &accessError
    ) else {
        fatal("failed to create access control: \(accessError?.takeRetainedValue().localizedDescription ?? "unknown")")
    }

    var query = baseQuery(service: service)
    query[kSecValueData as String] = data
    query[kSecAttrAccessControl as String] = accessControl

    let status = SecItemAdd(query as CFDictionary, nil)
    if status != errSecSuccess {
        fatal("failed to store item: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)")
    }

    fputs("Stored '\(service)' in Keychain (Touch ID protected)\n", stderr)
}

func getValue(service: String, context: LAContext) -> String {
    var query = baseQuery(service: service)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = context

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound {
        fputs("Error: '\(service)' not found in Keychain\n", stderr)
        fputs("  Run: touchenv store \(service)\n", stderr)
        exit(1)
    }

    if status != errSecSuccess {
        fatal("failed to retrieve item: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)")
    }

    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
        fatal("failed to decode item data")
    }

    return value
}

func get(service: String) {
    let context = requireTouchID(reason: "-> touchenv get \(service)")
    print(getValue(service: service, context: context), terminator: "")
}

func delete(service: String) {
    let _ = requireTouchID(reason: "-> touchenv delete \(service)")

    let status = SecItemDelete(baseQuery(service: service) as CFDictionary)

    if status == errSecItemNotFound {
        fatal("'\(service)' not found in Keychain")
    }
    if status != errSecSuccess {
        fatal("failed to delete item: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)")
    }

    fputs("Deleted '\(service)' from Keychain\n", stderr)
}

func list() {
    let _ = requireTouchID(reason: "-> touchenv list")

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    if status == errSecItemNotFound { return }
    if status != errSecSuccess {
        fatal("failed to list items: \(SecCopyErrorMessageString(status, nil) ?? "unknown" as CFString)")
    }

    guard let items = result as? [[String: Any]] else { return }

    for item in items {
        if let service = item[kSecAttrService as String] as? String {
            print(service)
        }
    }
}

func exec(envFile: String, command: [String]) {
    let contents: String
    do {
        contents = try String(contentsOfFile: envFile, encoding: .utf8)
    } catch {
        fatal("cannot read '\(envFile)': \(error.localizedDescription)")
    }

    var env = ProcessInfo.processInfo.environment
    let entries = parseEnvFile(contents)

    var keychainKeys: [String] = []
    for entry in entries {
        env[entry.key] = entry.value
        if entry.value.hasPrefix("touchenv:") {
            let keychainKey = String(entry.value.dropFirst("touchenv:".count))
            if let error = validateKeychainKey(keychainKey) {
                switch error {
                case .empty: fatal("touchenv: reference for '\(entry.key)' has empty key name")
                case .containsNull: fatal("touchenv: reference for '\(entry.key)' contains invalid characters")
                }
            }
            keychainKeys.append(keychainKey)
        }
    }

    if !keychainKeys.isEmpty {
        let cmdLabel = command.joined(separator: " ")
        let context = requireTouchID(reason: "-> touchenv exec \(envFile) -- \(cmdLabel)")

        for entry in entries where entry.value.hasPrefix("touchenv:") {
            let keychainKey = String(entry.value.dropFirst("touchenv:".count))
            env[entry.key] = getValue(service: keychainKey, context: context)
        }
    }

    if command.isEmpty {
        fatal("no command specified after --")
    }

    for (key, value) in env {
        setenv(key, value, 1)
    }

    let argv = command.map { strdup($0) } + [nil]
    execvp(command[0], argv)

    fatal("failed to exec '\(command[0])': \(String(cString: strerror(errno)))")
}

func usage() {
    fputs("""
    touchenv \(appVersion)

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
            let key = requireSingleArg(args, usage: "store <key>")
            store(service: key)

        case "get":
            let key = requireSingleArg(args, usage: "get <key>")
            get(service: key)

        case "delete":
            let key = requireSingleArg(args, usage: "delete <key>")
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

        case "--version", "-v", "version":
            print("touchenv \(appVersion)")

        case "--help", "-h", "help":
            usage()

        default:
            fputs("Unknown command: \(command)\n", stderr)
            usage()
            exit(1)
        }
    }
}
