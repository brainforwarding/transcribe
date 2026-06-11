// Transcribe — OpenAI proxy (Cloudflare Worker).
//
// Holds the shared org OpenAI key server-side so it never ships in the app. Each team
// member gets a personal token (set via the TEAM_TOKENS secret); the app sends it as the
// regular `Authorization: Bearer <token>` (pasted where the OpenAI key would go), and the
// Worker swaps it for the org key. Revoke a person by removing their token.
//
// TEAM_TOKENS format (secret, never in this file):  name:token,name:token
//   e.g.  sebastian:a1b2…,catalina:c3d4…
//
// Security posture (per review):
//  - Allowlists exactly two endpoints; rejects everything else.
//  - Strips ALL inbound headers; injects the org key server-side only.
//  - Validates the chat model; never forwards arbitrary models.
//  - Per-person hourly rate limit via KV (keyed by token owner's name).
//  - NEVER logs the audio body. Sanitized errors — neither key nor tokens are echoed.

const OPENAI = "https://api.openai.com";
const MAX_BODY = 26_214_400; // 25 MiB
const CHAT_MODELS = new Set(["gpt-4o", "gpt-4o-mini"]);
const RATE_PER_HOUR = 120;

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (request.method !== "POST") return err(405, "method not allowed");

      // Identity: personal team token in the standard Authorization header.
      const auth = request.headers.get("Authorization") || "";
      const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
      const who = token ? lookupToken(env.TEAM_TOKENS, token) : null;
      if (!who) return err(401, "not authenticated");

      // Per-person hourly rate limit.
      if (env.RATE) {
        const slot = Math.floor(Date.now() / 3_600_000);
        const key = `rl:${who}:${slot}`;
        const n = parseInt((await env.RATE.get(key)) || "0", 10);
        const cap = env.RATE_PER_HOUR ? +env.RATE_PER_HOUR : RATE_PER_HOUR;
        if (n >= cap) return err(429, "rate limit exceeded");
        await env.RATE.put(key, String(n + 1), { expirationTtl: 3600 });
      }

      const cl = request.headers.get("content-length");
      if (cl && +cl > MAX_BODY) return err(413, "payload too large");

      const ct = request.headers.get("content-type") || "";

      if (url.pathname === "/v1/audio/transcriptions") {
        if (!ct.includes("multipart/form-data")) return err(415, "expected multipart/form-data");
        // Stream the (large) audio body straight through — never read or log it.
        return forward(url.pathname, ct, request.body, env);
      }

      if (url.pathname === "/v1/chat/completions") {
        if (!ct.includes("application/json")) return err(415, "expected application/json");
        let payload;
        try { payload = await request.json(); } catch { return err(400, "invalid json"); }
        if (!CHAT_MODELS.has(payload.model)) return err(403, "model not allowed");
        return forward(url.pathname, "application/json", JSON.stringify(payload), env);
      }

      return err(403, "endpoint not allowed");
    } catch (e) {
      // Never leak internals (or the key) in errors.
      return err(502, "upstream error");
    }
  },
};

// TEAM_TOKENS = "name:token,name:token". Returns the owner's name, or null.
function lookupToken(teamTokens, presented) {
  if (!teamTokens) return null;
  for (const pair of teamTokens.split(",")) {
    const i = pair.indexOf(":");
    if (i < 1) continue;
    const name = pair.slice(0, i).trim();
    const token = pair.slice(i + 1).trim();
    if (token && timingSafeEqual(token, presented)) return name;
  }
  return null;
}

// Constant-time string comparison (avoids early-exit timing differences).
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function forward(path, contentType, body, env) {
  const headers = new Headers();
  headers.set("Authorization", `Bearer ${env.OPENAI_API_KEY}`);
  headers.set("Content-Type", contentType);
  const upstream = await fetch(OPENAI + path, { method: "POST", headers, body });
  const out = new Headers();
  out.set("Content-Type", upstream.headers.get("content-type") || "application/json");
  return new Response(upstream.body, { status: upstream.status, headers: out });
}

function err(status, message) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
