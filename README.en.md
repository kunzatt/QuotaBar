# QuotaBar

[한국어](README.md)

QuotaBar is a macOS menu-bar app for checking the remaining quota across multiple ChatGPT Codex accounts and Claude Code (claude.ai Pro and Max) accounts. It shows the primary account's remaining quota in the menu bar (for example, `41%`) and opens a usage panel focused on reset times and account health on click. Hovering shows a tooltip for the primary account. The app follows the system light or dark appearance.

Finder and the Desktop use a dedicated app icon: a blue gauge symbol with bold `Quota Bar` text below it. The menu bar shows the same gauge.

> Screenshot placeholder: capture the menu-bar item and popover after the first launch and add them here.

## Homebrew installation and remote updates

The release ZIP and Homebrew Cask currently support Apple Silicon Macs running macOS Sonoma (14) or later. The Cask token is `quotabar`.

```zsh
brew tap kunzatt/quotabar https://github.com/kunzatt/QuotaBar.git
brew trust --cask kunzatt/quotabar/quotabar
brew install --cask quotabar
```

After that one-time setup, use only `brew install --cask quotabar` and `brew upgrade --cask quotabar`.

After a new version has been published as a GitHub Release, update it remotely with:

```zsh
brew update
brew upgrade --cask quotabar
```

### Moving from CodexBar

QuotaBar is the new name starting with 0.2.0; the app was previously called CodexBar (`codexbar-for-mac`). If you already use CodexBar, quit it and run the commands below. Do not add `--zap`, so your account data is kept.

```zsh
brew uninstall --cask codexbar-for-mac
brew untap kunzatt/codex-bar-for-mac
brew tap kunzatt/quotabar https://github.com/kunzatt/QuotaBar.git
brew trust --cask kunzatt/quotabar/quotabar
brew install --cask quotabar
```

On first launch QuotaBar moves the account data from `~/Library/Application Support/CodexBar` to the `QuotaBar` folder, so your connected accounts carry over. If launch at login was on, it is registered again for the new app.

To remove the app and its locally managed login profiles:

```zsh
brew uninstall --zap --cask quotabar
```

To prepare a release, bump `CFBundleShortVersionString`, then create the GitHub Release ZIP and its SHA-256 checksum:

```zsh
./scripts/package-release.sh
```

Put the generated checksum in `Casks/quotabar.rb`, then upload the ZIP to the `v<version>` GitHub Release with the same version.

## Requirements

- Release ZIP/Homebrew Cask: Apple Silicon Mac running macOS Sonoma (14) or later
- Building from source: Apple Silicon or Intel Mac running macOS Sonoma (14) or later, with full Xcode (recommended) or Swift 6 command-line tools
- The ChatGPT app or Codex CLI. The default discovery path is `/Applications/ChatGPT.app/Contents/Resources/codex`.
- A Codex account on a ChatGPT Plus, Pro, or Pro Lite plan
- For Claude Code accounts: the Claude Code CLI (`claude`) and a claude.ai Pro or Max subscription. QuotaBar looks in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, then PATH.

For Codex accounts, QuotaBar uses no OpenAI Platform API keys, web scraping, or unofficial REST endpoints. It only calls local `codex app-server --stdio` processes.

Claude Code has no local protocol for asking about usage. For Claude Code accounts, QuotaBar therefore calls `https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's `/usage` screen. It is undocumented and may change without notice.

## Build and run

With Xcode installed, open [QuotaBar.xcodeproj](QuotaBar.xcodeproj/project.pbxproj) and run the `QuotaBar` scheme. The application is configured as an `LSUIElement`, so it appears only in the menu bar and has no Dock icon.

You can also build from Terminal:

```zsh
cd QuotaBar
./scripts/build.sh
```

Create an application bundle that can run without a Terminal window:

```zsh
cd QuotaBar
./scripts/package-app.sh
open dist/QuotaBar.app
```

Move `dist/QuotaBar.app` to `/Applications` to launch it through Finder or Spotlight. Do not run the app from Terminal and Finder at the same time, or the menu-bar item will appear twice.

To replace an app installed at one location, quit it first and run:

```zsh
cd QuotaBar
./scripts/install-or-update.sh "$HOME/Applications/QuotaBar.app"
```

The script moves the prior bundle to Trash, so it can be recovered if necessary. To keep using a different location, pass that path instead. For example, update a Desktop install with `./scripts/install-or-update.sh "$HOME/Desktop/QuotaBar.app"`.

Without full Xcode, the build script falls back to Swift Package Manager. This verifies that the source compiles; launching the menu-bar UI still requires a macOS GUI session.

## Tests

Run the framework-free unit-test runner with:

```zsh
cd QuotaBar
./scripts/test.sh
```

The tests cover JSONL response and notification decoding, multiple quota buckets, primary and secondary windows, null payloads, `Int64` token totals, malformed JSONL recovery, duration formatting, backoff, metadata persistence, log redaction, Claude usage mapping, Claude Keychain item naming, and Claude profile creation and removal. They do not read authentication files or perform an account login.

## Add the first account

1. Click `C --` in the menu bar and choose **Add account**.
2. Choose an alias and select **Start Device Code Login**.
3. In the browser, sign in to the desired ChatGPT Plus, Pro, or Pro Lite account and enter the displayed device code.
4. When the login-complete notification appears, QuotaBar reloads the account, plan, and quota data.

Repeat this process for each additional account. Each account has a separate `CODEX_HOME` and `codex app-server` process, so authentication never mixes between profiles.

To use the default Codex login in `~/.codex`, choose **Register default ~/.codex** in Settings. That profile is marked as external; QuotaBar does not delete that directory or its authentication files.

### Claude Code accounts

1. In **Connect account**, switch the service to **Claude Code**, enter an alias, and continue.
2. Claude Code opens the browser. Sign in to the claude.ai account you want, and the login completes on its own. If the browser shows a code instead, paste it into the QuotaBar window and submit it.
3. Each account uses its own `CLAUDE_CONFIG_DIR`, so logins never mix. To use the default login you already use in the terminal (`~/.claude`), choose **Use default ~/.claude** in Settings.

Claude usage shows the five-hour and weekly limits. The menu bar shows what is left of the five-hour limit, and any per-model weekly limits appear as separate rows in the popover. Background refreshes run on the same schedule as Codex, but each account calls the unofficial API at most about once a minute. When the API answers 429, QuotaBar waits for the longer of `Retry-After` and a backoff that grows from 5 minutes to 1 hour.

When an account requires a login, choose **Sign in again** from the usage popover or Settings to start Device Code Login. The existing profile and quota history stay in place; only the credentials for the account completed in the browser are refreshed.

## Primary account and refreshes

- Use the star next to an account in the full panel or Settings to set the primary account. Clicking the row itself never changes this preference.
- The menu-bar item prefers the primary account's `codex` bucket. If unavailable, it uses the first available bucket.
- Rate limits refresh every 30 seconds per account; token totals refresh every two minutes.
- QuotaBar requests an account-token refresh only when it starts a new local app-server process; ordinary polling does not force a new login or token rotation.
- When a request fails, the latest valid value remains visible and retries back off from 30 to 60, 120, and 300 seconds. All accounts refresh immediately after the Mac wakes from sleep.

## Data and security

Account metadata created by the app is stored here:

```text
~/Library/Application Support/QuotaBar/
├── accounts.json
├── Accounts/<account-uuid>/codex-home/
└── Accounts/<account-uuid>/claude-home/
```

The application-support directory and each account directory are kept at `0700`; metadata and generated `auth.json` are kept at `0600` where possible. `accounts.json` stores only the alias, UUID, local path, and enabled/primary-account settings.

QuotaBar never reads or parses the contents of `auth.json`.

Claude Code accounts are the exception. To call the usage API, QuotaBar uses `/usr/bin/security` to read the OAuth access token that Claude Code stores in the macOS Keychain. The token stays in memory and is sent only to `api.anthropic.com`. When the token is within two minutes of expiry or the API rejects it, QuotaBar runs `claude auth login` with `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` in an empty scratch profile, so Claude Code redeems the refresh token. Only a complete new token is written back to the original Keychain item, using the same `security -i` path Claude Code uses. A failed renewal leaves the original login untouched, and the scratch profile and its Keychain item are deleted right away. Sign-in and sign-out also go through `claude auth login` and `claude auth logout`. It does not store tokens, cookies, API keys, prompts, or conversations. stderr is drained only to prevent a blocked process and is not persisted; visible error messages are kept generic so credentials are not exposed.

## Known limitations

- `codex app-server` is experimental in the Codex CLI. A CLI update may change response schemas, so raw JSON is isolated at the `ProtocolMapper` boundary.
- The Plus five-hour limit is shown when the Codex response includes a 300-minute bucket. If the server returns only the weekly bucket, QuotaBar does not estimate the missing value and shows the weekly limit with an explanation.
- Version 1 covers ChatGPT Codex usage only. API costs, other plan-specific optimisations, automatic account switching, and automatic reset-credit spending are out of scope.
- The Claude usage API is unofficial. If Anthropic changes its format or authentication, Claude account refreshes may stop. Codex accounts are unaffected.
- Per-account Claude Keychain items follow Claude Code's current naming rule (`Claude Code-credentials-<first 8 hex digits of SHA-256 of CLAUDE_CONFIG_DIR>`). If Claude Code changes that rule, the affected account shows as needing sign-in.
- Device-code login and menu-bar interaction need a GUI session and a signed-in account to test.

## Troubleshooting

**Codex executable cannot be found**

Select the `codex` executable in Settings. The ChatGPT app usually bundles it at `/Applications/ChatGPT.app/Contents/Resources/codex`.

**Login is required**

QuotaBar shows this only for an explicit authentication failure. A temporary refresh or server failure remains retryable and is retried automatically. If the state persists, add the account again from the popover. For an external `~/.codex` profile, complete your normal Codex CLI login first, then refresh QuotaBar.

**No usage is displayed**

Check that the Codex CLI is current and verify the executable path in Settings. An account can be registered even when plan or quota data is unavailable; in that case the app preserves `C --` and the latest generic error state.

**Gatekeeper says that “QuotaBar” cannot be opened**

The current GitHub/Homebrew build is a personal distribution build and has not yet been notarized with an Apple Developer ID. If the warning appears, try opening the app once in Finder, then select **System Settings → Privacy & Security → Open Anyway**. Do not disable Gatekeeper globally. This notice will be removed once a Developer ID-signed and Apple-notarized release is available.

**Removing the app and authentication files**

For an app-managed profile, choose **Log out and delete local profile** in Settings to remove only that account's UUID folder. External profiles, including `~/.codex`, are removed from the list only. Deleting the app does not remove authentication files; remove `~/Library/Application Support/QuotaBar` manually only if you intentionally want to erase app-managed data.
