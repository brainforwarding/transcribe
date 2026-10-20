# Transcribe proxy (shared-key, team tokens)

This Cloudflare Worker holds the **shared org OpenAI key** so it never ships on coworkers'
machines. Each team member enters a **personal token** in Settings → Connection → Team,
and the Worker swaps it for the org key server-side. A person can also choose OpenAI
and enter their own API key without rebuilding the app.

## Deploy (~10 min, one-time)

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
   Paste the returned `id` into `wrangler.toml` under `[[kv_namespaces]]`.
3. Deploy, then store the secrets (encrypted, never in the repo):
   ```bash
   wrangler deploy                        # note the resulting workers.dev URL
   wrangler secret put OPENAI_API_KEY     # paste your sk-… when prompted
   wrangler secret put TEAM_TOKENS        # "name:token,name:token" — see below
   ```
4. Point the app at the Worker: set `Config.proxyBaseURL` in
   `TranscribeBar/Sources/TranscribeApp/Config.swift` to `https://<worker-url>/v1` and rebuild.

## Team tokens

Generate one random token per person and join them as `name:token,name:token`:

```bash
openssl rand -hex 16        # one per person
```

Keep tokens canonically in 1Password; `proxy/TEAM_TOKENS.local` is a legacy gitignored
working copy. Each person enters their token in Settings → Connection → Team. The name
is only used for per-person rate-limiting. Existing credentials must not be rotated or
replaced without the owner's explicit authorization.

- **Add/rename/remove a person:** edit the list, re-run `wrangler secret put TEAM_TOKENS`
  with the new combined value (takes effect in seconds, no redeploy).
- **Rotate the org key:** `wrangler secret put OPENAI_API_KEY`.
- **Cost backstop:** set a hard spending limit on the OpenAI org, and apply for
  **Zero-Data-Retention (ZDR)** so audio isn't retained.

## What the Worker enforces

- POST file transcription (`/v1/audio/transcriptions`) and chat (`/v1/chat/completions`), plus GET transcription-only WebSocket upgrades (`/v1/realtime?intent=transcription`). Other POST endpoints are denied; unsupported methods return 405.
- All inbound headers stripped; the org key is injected server-side only.
- Chat models allowlisted (`gpt-4o`, `gpt-4o-mini`, `gpt-6-luna`); 25 MiB body cap.
  Native dictation uses Luna with `reasoning_effort: none` for its punctuation and
  paragraph pass. Meeting summaries retain their existing models.
- Per-person hourly rate limit (`RATE_PER_HOUR`, default 120) keyed by the token owner. Each live source connection counts toward this best-effort KV limit.
- Live sessions accept only 24 kHz PCM and `gpt-live-transcribe` transcription settings, audio appends, commits and clears. Assistant responses and tools are rejected. Connection lifetime, frame size/rate and unacknowledged audio are bounded. `delay: minimal` supports the single-item five-minute dictation stream with a 20 MiB base64 audio cap; existing `low` meeting sessions keep their 2 MiB cap. Both modes retain ordered commit/clear acknowledgment checks. Unknown errors are sanitized; known account errors retain safe codes for user remedies.
- Constant-time token comparison; audio bodies are streamed, never read or logged; errors
  are sanitized — neither the key nor tokens are ever echoed.

> The previous Cloudflare Access (SSO) variant lives in git history; team tokens replaced it
> because the app-side SSO sign-in flow was never built and tokens require zero app changes.
