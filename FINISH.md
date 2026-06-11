# Operating & shipping Transcribe.app

Everything below is already set up. This is the runbook for shipping updates and managing the
team. The signing identity is **Developer ID Application: ED4.ONE SpA (`K542ZFQH6B`)** and the
notarization profile in the Keychain is **`meetrec-notary`**.

> The Python CLI (`meetrec.py`) is a separate tool and is untouched by any of this.

## How auth works (shared-key team tokens)

Coworkers do **not** paste an OpenAI key. The org key lives only in the Cloudflare Worker
(`proxy/`). Each person pastes a **personal team token** where the app asks for one; the Worker
validates it and swaps in the org key server-side. The app is pointed at the Worker via
`Config.proxyBaseURL` (`TranscribeBar/Sources/TranscribeApp/Config.swift`):

```
https://transcribe-proxy.quiet-bush-25b1.workers.dev/v1
```

Tokens live in `proxy/TEAM_TOKENS.local` (gitignored, never committed). Full proxy details:
[`proxy/README.md`](proxy/README.md).

## Distribution (GitHub Releases)

The notarized DMG ships as a GitHub Release. Coworkers always download from the same link:

```
https://github.com/brainforwarding/transcribe/releases/latest
```

Send each person that link **plus their token** (from `proxy/TEAM_TOKENS.local`). Install steps
are written into each release's notes; the app shows its version at the bottom-left of Settings
so people can confirm they're on the latest.

## Ship an update (~5 min)

1. Make your changes. Bump the version in `TranscribeBar/scripts/make-app.sh`
   (`CFBundleShortVersionString`).
2. Build, sign, notarize:
   ```bash
   cd TranscribeBar
   SIGN_IDENTITY="Developer ID Application: ED4.ONE SpA (K542ZFQH6B)" ./scripts/make-app.sh release
   NOTARY_PROFILE="meetrec-notary" ./scripts/notarize.sh
   ```
   Output: **`build/Transcribe.dmg`**, notarized and stapled (works offline on first open).
   Verify Gatekeeper sees it: `spctl -a -vvv -t install build/Transcribe.app` → `accepted`.
3. Publish the release:
   ```bash
   cd ..
   gh release create v1.0.1 TranscribeBar/build/Transcribe.dmg \
     --title "Transcribe 1.0.1" --notes "What changed…"
   ```
4. Tell the team "v1.0.1 is up, grab it from the Releases link." They check ⚙ Settings to
   confirm the version.

## Manage the team

- **Add / rename / remove a person:** edit `proxy/TEAM_TOKENS.local` (one `name:token` per
  person; `openssl rand -hex 16` for a new token), then push the combined value:
  ```bash
  cd proxy && wrangler secret put TEAM_TOKENS < TEAM_TOKENS.secret.local
  ```
  Takes effect in seconds, no redeploy, no new app build. Removing a token revokes that person.
- **Rotate the org key:** `wrangler secret put OPENAI_API_KEY`.
- **Rate limit:** `RATE_PER_HOUR` in `proxy/wrangler.toml` (default 120/person/hour).

## Build from source (no signing)

For local dev without distributing, ad-hoc sign is fine:
```bash
cd TranscribeBar
./scripts/make-app.sh        # builds build/Transcribe.app (ad-hoc)
open build/Transcribe.app    # waveform icon in the menu bar
```

## One-time setup (already done — kept for reference / a new signing machine)

- **Developer ID Application cert** (ED4.ONE SpA): created via Keychain Access → *Certificate
  Assistant → Request a Certificate from a Certificate Authority* (save the CSR to disk) →
  developer.apple.com → Certificates → **+** → **Developer ID Application** → upload CSR →
  download `.cer` → double-click to install into the **login** keychain. Verify:
  `security find-identity -v -p codesigning` shows `Developer ID Application: ED4.ONE SpA (K542ZFQH6B)`.
  To sign from another Mac, export the cert+key as a `.p12` (Keychain Access → right-click →
  Export) and import it there.
- **Notarization credentials:** `xcrun notarytool store-credentials "meetrec-notary"
  --apple-id "you@example.com" --team-id "K542ZFQH6B"` (paste an app-specific password from
  appleid.apple.com → Sign-In & Security). Stored in the Keychain; no file to keep.
- **Entitlement:** `TranscribeBar/Transcribe.entitlements` keychain-access-group prefix must be
  the signing Team ID (`K542ZFQH6B.com.sebastianmarambio.transcribe`). A mismatch causes a
  `-34018` Keychain error at runtime.
- **Proxy deploy:** see [`proxy/README.md`](proxy/README.md) (wrangler, KV namespace, the
  `OPENAI_API_KEY` and `TEAM_TOKENS` secrets).

## Cost & privacy backstops

Set a hard spending limit on the OpenAI org (the team shares one key), and request
**Zero-Data-Retention (ZDR)** so uploaded audio isn't retained.
