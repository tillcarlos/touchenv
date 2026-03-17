# touchenv

Store secrets in macOS Keychain. Unlock with Touch ID. Use them in `.env` files.

No plaintext keys in your repo. No extra services. Just your fingerprint.

## Install

```bash
brew install tillcarlos/tap/touchenv
```

Or build from source:

```bash
git clone https://github.com/tillcarlos/touchenv.git
cd touchenv
make install
```

## Usage

### Store a secret

```bash
touchenv store MY_SECRET
Enter value for 'MY_SECRET': ********
Stored 'MY_SECRET' in Keychain (Touch ID protected)
```

Or pipe it in:

```bash
echo "s3cret" | touchenv store MY_SECRET
```

### Retrieve a secret

```bash
touchenv get MY_SECRET   # Touch ID prompt → prints value
```

### Use in `.env` files

Reference Keychain secrets with the `touchenv:` prefix:

```bash
# .env.staging
DB_HOST=10.0.0.5
PORT=8443
NODE_KEY=touchenv:MY_NODE_KEY
REGISTRY_PASSWORD=touchenv:MY_REGISTRY_PASSWORD
```

Then run your command through `touchenv exec`:

```bash
touchenv exec .env.staging -- bin/deploy.sh staging
```

One Touch ID prompt unlocks all secrets, resolves the `.env` file, and runs your command.

### npm scripts

```json
{
  "scripts": {
    "deploy:staging": "touchenv exec .env.staging -- bin/deploy.sh staging",
    "credentials:staging": "touchenv exec .env.staging -- tsx src/scripts/credentials.ts staging"
  }
}
```

### All commands

```
touchenv store <key>                Store a secret (interactive prompt or pipe)
touchenv get <key>                  Retrieve a secret (Touch ID) → stdout
touchenv delete <key>               Remove from Keychain
touchenv list                       List stored keys
touchenv exec <envfile> -- <cmd>    Load .env, resolve touchenv: values, run cmd
```

## How it works

- Secrets are stored in the macOS Keychain as generic passwords
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — no iCloud sync, device-only
- `touchenv get` and `touchenv exec` require Touch ID (via `LAContext`) before reading any secret
- Other apps accessing the same Keychain item get a system password prompt
- 194KB universal binary (arm64 + x86_64), no dependencies

## Onboarding new devs

1. Install touchenv: `brew install tillcarlos/tap/touchenv`
2. Store the required secrets:
   ```bash
   touchenv store MY_NODE_KEY
   touchenv store MY_REGISTRY_PASSWORD
   ```
3. Run as usual: `pnpm deploy:staging`

If a secret is missing, touchenv tells them exactly what to do:

```
Error: 'MY_NODE_KEY' not found in Keychain
  Run: touchenv store MY_NODE_KEY
```

## Requirements

- macOS 12+
- Touch ID (or Apple Watch unlock)
- Swift 5.9+ (for building from source)

## License

MIT
