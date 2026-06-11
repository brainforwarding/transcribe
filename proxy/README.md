# Transcribe proxy (shared-key, team tokens)

This Cloudflare Worker holds the **shared org OpenAI key** so it never ships on coworkers'
machines. Each team member gets a **personal token**; they paste it into the app exactly
where an OpenAI key would go, and the Worker swaps it for the org key server-side. Revoking
a person = removing their token. **Optional:** the app also works with a per-user OpenAI
key (set `Config.proxyBaseURL = nil` and rebuild).

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

Keep the human-readable list in `proxy/TEAM_TOKENS.local` (gitignored). Each person pastes
*their token* into the app's key field (⚙ → Replace key). The name is only used for
per-person rate-limiting.

- **Add/rename/remove a person:** edit the list, re-run `wrangler secret put TEAM_TOKENS`
  with the new combined value (takes effect in seconds, no redeploy).
- **Rotate the org key:** `wrangler secret put OPENAI_API_KEY`.
- **Cost backstop:** set a hard spending limit on the OpenAI org, and apply for
  **Zero-Data-Retention (ZDR)** so audio isn't retained.

## What the Worker enforces

- Exactly two endpoints (`/v1/audio/transcriptions`, `/v1/chat/completions`); everything else 403.
- All inbound headers stripped; the org key is injected server-side only.
- Chat models allowlisted (`gpt-4o`, `gpt-4o-mini`); 25 MiB body cap.
- Per-person hourly rate limit (`RATE_PER_HOUR`, default 120) keyed by the token owner.
- Constant-time token comparison; audio bodies are streamed, never read or logged; errors
  are sanitized — neither the key nor tokens are ever echoed.

> The previous Cloudflare Access (SSO) variant lives in git history; team tokens replaced it
> because the app-side SSO sign-in flow was never built and tokens require zero app changes.
