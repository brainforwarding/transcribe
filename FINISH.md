# Finishing & sharing Transcribe.app

The app is built and runs locally (ad-hoc signed). These are the only steps that need your
Apple account / decisions. Nothing here needs Xcode.

> The Python CLI (`meetrec.py`) is untouched and still works — this app is separate.

## Run it locally right now (no account needed)
```bash
cd TranscribeBar
./scripts/make-app.sh debug
open build/Transcribe.app          # appears in the menu bar (waveform icon)
```
First run: accept the consent screen → paste your OpenAI key → click the two **Grant**
buttons → **Quit & Reopen** (Screen Recording needs a relaunch) → pick your mic → **Record**.

## Share with coworkers (notarized) — ~10 min, one-time
You already have the Apple account and **Team ID `47SAXBXKHA`**. You still need a
**Developer ID Application** certificate (your existing "Apple Development" cert is iOS-only
and can't sign a distributable Mac app).

1. **Create the cert (no Xcode):**
   - Keychain Access → *Certificate Assistant → Request a Certificate from a Certificate
     Authority* → your email, "Saved to disk" → save the `.certSigningRequest`.
   - developer.apple.com/account → Certificates → **+** → **Developer ID Application** →
     upload the CSR → download the `.cer` → double-click to install.
   - Verify: `security find-identity -v -p codesigning` shows
     `Developer ID Application: Sebastian Marambio (47SAXBXKHA)`.
2. **Store notarization credentials** (one-time; run it yourself so the password stays local):
   ```bash
   xcrun notarytool store-credentials "meetrec-notary" \
     --apple-id "you@example.com" --team-id "47SAXBXKHA" --password "APP-SPECIFIC-PASSWORD"
   ```
   (App-specific password: appleid.apple.com → Sign-In & Security.)
3. **Build, sign, notarize, package:**
   ```bash
   cd TranscribeBar
   SIGN_IDENTITY="Developer ID Application: Sebastian Marambio (47SAXBXKHA)" ./scripts/make-app.sh release
   NOTARY_PROFILE="meetrec-notary" ./scripts/notarize.sh
   ```
   Output: **`build/Transcribe.dmg`** — notarized, send it to coworkers. They drag it to
   Applications and open (no Gatekeeper friction).

   *If Keychain save fails with `-34018` on a coworker's Mac:* the entitlement
   `keychain-access-groups` is already set to `47SAXBXKHA.com.sebastianmarambio.transcribe`
   in `TranscribeBar/Transcribe.entitlements`; just rebuild.

## Optional: shared-key SSO via Cloudflare (so coworkers need no OpenAI key)
By default each person pastes their own key. To switch to company-paid billing where coworkers
just **sign in** (the org key stays server-side), deploy the proxy — ~20 min, one-time. Fuller
notes in [`proxy/README.md`](proxy/README.md); the concrete steps:

1. **Install + log in:**
   ```bash
   npm i -g wrangler && wrangler login
   ```
2. **Rate-limit store:**
   ```bash
   cd proxy && wrangler kv namespace create RATE
   ```
   Paste the returned `id` into `proxy/wrangler.toml` (uncomment the `[[kv_namespaces]]` block).
3. **Store the org key (encrypted, never in the repo):**
   ```bash
   wrangler secret put OPENAI_API_KEY      # paste your sk-… when prompted
   ```
4. **Deploy:**
   ```bash
   wrangler deploy                          # note the URL, e.g. https://transcribe-proxy.<you>.workers.dev
   ```
5. **Put it behind Cloudflare Access** (Zero Trust dashboard → Access → Applications →
   *Self-hosted*): set the app to the Worker URL, add an identity provider (Google/GitHub/Okta)
   and a policy *Allow: emails ending in @yourcompany.com*.
6. **Point the app at it:** in `TranscribeBar/Sources/TranscribeApp/Config.swift`, set
   `proxyBaseURL` to your Worker URL (e.g. `…workers.dev/v1`), then rebuild (`make-app.sh`).
   (The SSO sign-in flow in the app is the one remaining integration for this mode — see
   `proxy/README.md`.)

**Operate:** add/remove a user = edit the Access policy · rotate the key = `wrangler secret
put OPENAI_API_KEY` · costs land on the org key.

## Apply for OpenAI Zero-Data-Retention
Before sharing widely, request **ZDR** on the OpenAI org so uploaded audio isn't retained,
and set a hard spending limit as a cost backstop.
