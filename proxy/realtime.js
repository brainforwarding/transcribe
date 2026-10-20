// Transcription-only relay. Never forward arbitrary OpenAI session settings.
export const LIVE_MODEL = 'gpt-live-transcribe';
const MAX_FRAME = 196608;
const MAX_AUDIO = 65536;
const errorCodes = new Set(['invalid_api_key', 'insufficient_quota', 'credit_balance_exhausted',
  'project_spend_limit_exceeded', 'organization_spend_limit_exceeded', 'organization_usage_limit_exceeded',
  'billing_hard_limit_reached', 'rate_limit_exceeded', 'slow_down', 'model_not_found',
  'permission_denied', 'account_deactivated', 'invalid_request_error', 'not_authenticated',
  'access_denied', 'model_not_allowed', 'invalid_value', 'invalid_request', 'invalid_config']);
const errorTypes = new Set(['insufficient_quota', 'invalid_request_error', 'authentication_error',
  'permission_error', 'rate_limit_error', 'server_error', 'transcription_error']);
const MAX_UNACKNOWLEDGED_AUDIO = 2 * 1024 * 1024;
// Five minutes of 24 kHz mono PCM16 is 19.2 MB in base64; keep a bounded margin.
const MAX_CONTINUOUS_AUDIO = 20 * 1024 * 1024;

function safeError(error, fallback = 'transcription_unavailable') {
  return { type: errorTypes.has(error?.type) ? error.type : 'transcription_error',
    code: errorCodes.has(error?.code) ? error.code : fallback,
    ...(error?.event_id !== undefined ? { event_id: serverID(error.event_id) } : {}) };
}
function serverID(value) {
  if (typeof value !== 'string' || !value.length || value.length > 512 || !/^[\w.-]+$/.test(value)) throw new Error('invalid upstream id');
  return value;
}

function eventID(value) {
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || value.length > 128 || !/^[\w.-]+$/.test(value)) throw new Error('invalid event id');
  return value;
}
function hints(values, maxCount, maxLength) {
  if (values === undefined) return undefined;
  if (!Array.isArray(values) || values.length > maxCount || values.some(v => typeof v !== 'string' || !v.trim() || v.length > maxLength || /[\r\n<>]/.test(v))) throw new Error('invalid hints');
  if (values.join('').length > 8192) throw new Error('hints too large');
  return values;
}
export function clientFrame(raw) {
  if (typeof raw !== 'string' || raw.length > MAX_FRAME) throw new Error('invalid frame');
  const p = JSON.parse(raw);
  if (!p || typeof p !== 'object' || Array.isArray(p)) throw new Error('invalid frame');
  const id = eventID(p.event_id);
  const out = { type: p.type, ...(id ? { event_id: id } : {}) };
  if (p.type === 'session.update') {
    const s = p.session, input = s?.audio?.input, t = input?.transcription;
    if (s?.type !== 'transcription' || input?.format?.type !== 'audio/pcm' || input?.format?.rate !== 24000 || t?.model !== LIVE_MODEL || (input.turn_detection !== undefined && input.turn_detection !== null)) throw new Error('unsupported session');
    // Reject extra fields rather than silently accepting a voice/assistant request.
    const allowed = (o, keys) => o && typeof o === 'object' && !Array.isArray(o) && Object.keys(o).every(k => keys.includes(k));
    if (!allowed(p, ['type','event_id','session']) || !allowed(s, ['type','audio']) || !allowed(s.audio, ['input']) || !allowed(input, ['format','transcription','turn_detection']) || !allowed(input.format, ['type','rate']) || !allowed(t, ['model','delay','languages','keywords']) || (t.delay !== undefined && !['minimal', 'low'].includes(t.delay))) throw new Error('unsupported settings');
    const languages = hints(t.languages, 20, 35), keywords = hints(t.keywords, 100, 100);
    out.session = { type: 'transcription', audio: { input: { format: { type: 'audio/pcm', rate: 24000 }, transcription: { model: LIVE_MODEL, delay: t.delay ?? 'low', ...(languages ? { languages } : {}), ...(keywords ? { keywords } : {}) }, turn_detection: null } } };
  } else if (p.type === 'input_audio_buffer.append') {
    if (Object.keys(p).some(k => !['type','event_id','audio'].includes(k)) || typeof p.audio !== 'string' || !p.audio.length || p.audio.length > MAX_AUDIO || p.audio.length % 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(p.audio)) throw new Error('invalid audio');
    const bytes = p.audio.length / 4 * 3 - (p.audio.endsWith('==') ? 2 : p.audio.endsWith('=') ? 1 : 0);
    if (bytes % 2) throw new Error('invalid pcm');
    out.audio = p.audio;
  } else if (p.type === 'input_audio_buffer.commit' || p.type === 'input_audio_buffer.clear') {
    if (Object.keys(p).some(k => !['type','event_id'].includes(k))) throw new Error('unsupported settings');
  } else throw new Error('event not allowed');
  return out;
}
export function serverFrame(raw) {
  if (typeof raw !== 'string' || raw.length > 262144) throw new Error('invalid upstream frame');
  const p = JSON.parse(raw);
  if (!p || typeof p !== 'object' || Array.isArray(p)) throw new Error('invalid upstream frame');
  const metadata = { ...(p.event_id !== undefined ? { event_id: serverID(p.event_id) } : {}) };
  if (p.type === 'error' || p.type === 'conversation.item.input_audio_transcription.failed') {
    return { type: p.type, ...metadata, ...(p.item_id !== undefined ? { item_id: serverID(p.item_id) } : {}),
      ...(Number.isInteger(p.content_index) && p.content_index >= 0 ? { content_index: p.content_index } : {}), error: safeError(p.error) };
  }
  if (['session.created', 'session.updated', 'transcription_session.created', 'transcription_session.updated'].includes(p.type)) {
    if (p.session?.type !== undefined && p.session.type !== 'transcription') throw new Error('unsupported upstream session');
    const expires = p.session?.expires_at;
    return { type: p.type, ...metadata, session: { type: 'transcription',
      ...(Number.isSafeInteger(expires) && expires > 0 ? { expires_at: expires } : {}) } };
  }
  if (p.type === 'input_audio_buffer.committed') return { type: p.type, ...metadata, item_id: serverID(p.item_id),
    ...(p.previous_item_id !== undefined ? { previous_item_id: p.previous_item_id === null ? null : serverID(p.previous_item_id) } : {}) };
  if (p.type === 'input_audio_buffer.cleared') return { type: p.type, ...metadata };
  if (p.type === 'conversation.item.input_audio_transcription.delta' || p.type === 'conversation.item.input_audio_transcription.completed') {
    const field = p.type.endsWith('.delta') ? 'delta' : 'transcript';
    if (typeof p[field] !== 'string' || (p.content_index !== undefined && (!Number.isInteger(p.content_index) || p.content_index < 0))) throw new Error('invalid upstream transcript');
    return { type: p.type, ...metadata, item_id: serverID(p.item_id),
      ...(p.content_index !== undefined ? { content_index: p.content_index } : {}), [field]: p[field] };
  }
  return null;
}

async function handshakeError(upstream) {
  const fallback = upstream.status === 401 ? 'invalid_api_key' : upstream.status === 403 ? 'permission_denied'
    : upstream.status === 429 ? 'rate_limit_exceeded' : 'transcription_unavailable';
  let detail;
  const reader = upstream.body?.getReader();
  try {
    if (reader) {
      const chunks = []; let length = 0;
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        length += value.byteLength;
        if (length > 16384) break;
        chunks.push(value);
      }
      if (length <= 16384) {
        const bytes = new Uint8Array(length); let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
        detail = JSON.parse(new TextDecoder().decode(bytes))?.error;
      }
    }
  } catch {} finally { try { await reader?.cancel(); } catch {} }
  // HTTP errors do not need an event ID, and never expose the upstream message.
  return { type: errorTypes.has(detail?.type) ? detail.type : 'transcription_error',
    code: errorCodes.has(detail?.code) ? detail.code
      : detail?.type === 'insufficient_quota' ? 'transcription_unavailable' : fallback };
}
export async function relayTranscription(request, env) {
  const url = new URL(request.url);
  if (url.search !== '?intent=transcription' || request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') return new Response('unsupported transcription request', { status: 400 });
  const handshakeController = new AbortController();
  const handshakeDeadline = setTimeout(() => handshakeController.abort(), 10000);
  let upstream;
  try {
    upstream = await fetch('https://api.openai.com/v1/realtime?intent=transcription', {
      headers: { Upgrade: 'websocket', Authorization: `Bearer ${env.OPENAI_API_KEY}` }, signal: handshakeController.signal });
  } finally { clearTimeout(handshakeDeadline); }
  // Never leave a pending abort timer attached to an upgraded live connection.
  if (upstream.status !== 101 || !upstream.webSocket) return new Response(JSON.stringify({ error: await handshakeError(upstream) }), {
    status: upstream.status === 429 ? 429 : upstream.status === 401 || upstream.status === 403 ? 403 : 502,
    headers: { 'Content-Type':'application/json' } });
  const pair = new WebSocketPair(), client = pair[0], socket = pair[1], remote = upstream.webSocket;
  let closed = false, configured = false, ready = false, tokens = 262144, events = 100, last = Date.now();
  let expiry, configurationTimeout, unacknowledgedAudio = 0, currentAudio = 0;
  let audioLimit = MAX_UNACKNOWLEDGED_AUDIO;
  const acknowledgments = [];
  const close = (code = 1000) => { if (closed) return; closed = true; clearTimeout(expiry); clearTimeout(configurationTimeout); try { socket.close(code, 'transcription session ended'); } catch {} try { remote.close(code, 'transcription session ended'); } catch {} };
  expiry = setTimeout(() => close(1000), 50 * 60 * 1000);
  configurationTimeout = setTimeout(() => close(1011), 10000);
  try { socket.accept(); remote.accept(); } catch { close(1011); throw new Error('transcription connection unavailable'); }
  socket.addEventListener('message', event => {
    if (closed) return;
    try {
      const elapsed = Math.max(0, Date.now() - last) / 1000; last = Date.now();
      tokens = Math.min(262144, tokens + elapsed * 131072); events = Math.min(100, events + elapsed * 30);
      if (typeof event.data !== 'string' || event.data.length > tokens || --events < 0) throw new Error('rate');
      tokens -= event.data.length;
      const p = clientFrame(event.data);
      if (p.type === 'session.update') { if (configured) throw new Error('already configured'); configured = true;
        if (p.session.audio.input.transcription.delay === 'minimal') audioLimit = MAX_CONTINUOUS_AUDIO; }
      else if (!ready) throw new Error('not configured');
      // Workers exposes no send-completion/backpressure API. Keep a bounded audio
      // window until the upstream acknowledges each ordered commit or clear.
      if (p.type === 'input_audio_buffer.append') {
        unacknowledgedAudio += p.audio.length; currentAudio += p.audio.length;
        if (unacknowledgedAudio > audioLimit) throw new Error('upstream stalled');
      } else if (p.type === 'input_audio_buffer.commit' || p.type === 'input_audio_buffer.clear') {
        if (acknowledgments.length >= 16) throw new Error('upstream stalled');
        acknowledgments.push({ type: p.type === 'input_audio_buffer.commit' ? 'input_audio_buffer.committed' : 'input_audio_buffer.cleared', bytes: currentAudio }); currentAudio = 0;
      }
      remote.send(JSON.stringify(p));
    } catch { close(1008); }
  });
  remote.addEventListener('message', event => {
    if (closed) return;
    try {
      const p = serverFrame(event.data); if (!p) return;
      if (p.type === 'session.updated' || p.type === 'transcription_session.updated') {
        if (!configured || ready) throw new Error('unexpected configuration');
        ready = true; clearTimeout(configurationTimeout);
      }
      if (p.type === 'input_audio_buffer.committed' || p.type === 'input_audio_buffer.cleared') {
        const pending = acknowledgments.shift();
        if (!pending || pending.type !== p.type) throw new Error('unexpected acknowledgement');
        unacknowledgedAudio -= pending.bytes;
      }
      socket.send(JSON.stringify(p));
      if (p.type === 'error' || p.type === 'conversation.item.input_audio_transcription.failed') close(1011);
    } catch { close(1011); }
  });
  for (const ws of [socket, remote]) { ws.addEventListener('close', () => close()); ws.addEventListener('error', () => close(1011)); }
  return new Response(null, { status: 101, webSocket: client });
}
