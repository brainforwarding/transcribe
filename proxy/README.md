# Transcribe proxy (optional — shared-key SSO)

This Cloudflare Worker holds the **shared org OpenAI key** so it never ships on coworkers'
machines. Coworkers sign in with company SSO (Cloudflare Access); the Worker injects the
key. **Optional:** the app works today with a per-user key pasted into the Keychain — deploy
this only when you want company-paid, no-per-user-setup billing.

## Deploy (~20 min, one-time)
1. Install wrangler + log in:
   ```bash
   npm i -g wrangler
   wrangler login
   ```
2. Rate-limit KV store:
   ```bash
   cd proxy
   wrangler kv namespace create RATE
   ```
   Paste the returned `id` into `wrangler.toml` under `[[kv_namespaces]]` (uncomment it).
3. Store the org key (encrypted, never in the repo):
   ```bash
   wrangler secret put OPENAI_API_KEY     # paste your sk-… when prompted
   ```
4. Deploy:
   ```bash
   wrangler deploy
   ```
   Note the resulting URL, e.g. `https://transcribe-proxy.<you>.workers.dev`.
5. **Put it behind Cloudflare Access** (Zero Trust dashboard → Access → Applications →
   Self-hosted): set the app domain to the Worker URL, add an **identity provider** (Google
   Workspace / GitHub / Okta) and a policy *Allow: emails ending in @yourcompany.com*. Access
   then injects `Cf-Access-Authenticated-User-Email`, which the Worker rate-limits on.

## Operate
- **Add/remove a user:** edit the Access policy (or the email list). Removing a user revokes
  access on their next request.
- **Rotate the key:** `wrangler secret put OPENAI_API_KEY` (takes effect in seconds).
- **Cost backstop:** also set a hard spending limit on the OpenAI org, and apply for
  **Zero-Data-Retention (ZDR)** so audio isn't retained.

## Point the app at it
In the app, set the proxy base URL (build constant `ProxyBaseURL` in `Config.swift`) to your
Worker URL and switch auth to the Access SSO flow. Until then the app uses the per-user
Keychain key against `api.openai.com` directly. The Worker never logs audio and only
forwards `POST /v1/audio/transcriptions` (whisper-1) and `POST /v1/chat/completions` (gpt-4o).
