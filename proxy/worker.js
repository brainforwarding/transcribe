// Transcribe — OpenAI proxy (Cloudflare Worker).
//
// Holds the shared org OpenAI key server-side so it never ships in the app. Put this Worker
// behind **Cloudflare Access** (OIDC against your company domain): Access authenticates each
// user and injects the `Cf-Access-Authenticated-User-Email` header we key rate-limits on.
//
// Security posture (per review):
//  - Allowlists exactly two endpoints; rejects everything else.
//  - Strips ALL inbound headers; injects the org key server-side only.
//  - Validates the chat model; never forwards arbitrary models.
//  - Per-user hourly rate limit via KV.
//  - NEVER logs the audio body. Sanitized errors — the key is never echoed.

const OPENAI = "https://api.openai.com";
const MAX_BODY = 26_214_400; // 25 MiB
const CHAT_MODELS = new Set(["gpt-4o", "gpt-4o-mini"]);
const RATE_PER_HOUR = 120;

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (request.method !== "POST") return err(405, "method not allowed");

      // Identity from Cloudflare Access (must be configured in front of this Worker).
      const email = request.headers.get("Cf-Access-Authenticated-User-Email");
      if (!email) return err(401, "not authenticated");

      // Per-user hourly rate limit.
      if (env.RATE) {
        const slot = Math.floor(Date.now() / 3_600_000);
        const key = `rl:${email}:${slot}`;
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
