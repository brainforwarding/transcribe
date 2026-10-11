"""Generates the animated README SVGs (docs/assets/dictation.svg, meetings.svg).

Pure CSS keyframes, one shared loop per file, Urbanist subset embedded as woff2.
Run: pip install fonttools brotli && python3 docs/assets/make-animations.py
"""
import base64, io, os, sys
from fontTools import subset
from fontTools.ttLib import TTFont

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FONTS = f"{REPO}/TranscribeBar/Sources/TranscribeApp/Resources/Fonts"
OUT = f"{REPO}/docs/assets"
os.makedirs(OUT, exist_ok=True)

LIGHT = dict(canvas="#E9EDF2", page="#F3F4F6", surface="#FFFFFF", chrome="#F3F4F6",
             subtle="#F3F4F6", selected="#CDE4FF", primary="#002654", body="#374151",
             muted="#5C6470", border="#E5E7EB", action="#0A72EF", err="#B42318",
             ok="#0E4A3B", okbg="#E3F4EF", orange="#D9622B", onaction="#FFFFFF")
DARK = dict(canvas="#06111F", page="#0B1B30", surface="#13263F", chrome="#1A2F4B",
            subtle="#1A2F4B", selected="#1E4579", primary="#FDFAF6", body="#C8D2E0",
            muted="#A5B4C9", border="#2A3F5F", action="#0A72EF", err="#F98A7E",
            ok="#A9DCCB", okbg="#134A3F", orange="#F08A60", onaction="#FFFFFF")


def palette_css():
    def block(p):
        rules = []
        for k, v in p.items():
            rules.append(f".f-{k}{{fill:{v}}}.s-{k}{{stroke:{v}}}")
        return "".join(rules)
    return block(LIGHT) + "@media (prefers-color-scheme: dark){" + block(DARK) + "}"


def font_face(text):
    chars = set(text) | set(" 0123456789:·.,'?-")
    css = []
    for weight, file in [(500, "Urbanist-Medium.ttf"), (600, "Urbanist-SemiBold.ttf"),
                         (700, "Urbanist-Bold.otf")]:
        font = TTFont(f"{FONTS}/{file}")
        opts = subset.Options()
        opts.flavor = "woff2"
        opts.layout_features = ["kern", "liga"]
        sub = subset.Subsetter(opts)
        sub.populate(text="".join(sorted(chars)))
        sub.subset(font)
        buf = io.BytesIO()
        font.flavor = "woff2"
        font.save(buf)
        data = base64.b64encode(buf.getvalue()).decode()
        css.append(f"@font-face{{font-family:U;font-weight:{weight};"
                   f"src:url(data:font/woff2;base64,{data}) format('woff2')}}")
    return "".join(css)


class Anim:
    """Collects opacity timelines (percent windows) for one shared loop."""

    def __init__(self, duration):
        self.duration = duration
        self.rules = []
        self.n = 0

    def show(self, windows, final=None, fade=0.8, low=0.0, high=1.0):
        """windows: list of (start, end) percents where the element is visible."""
        self.n += 1
        name = f"a{self.n}"

        def value(t):
            v = low
            for a, b in windows:
                if a <= t <= b:
                    return high
                if a - fade < t < a:
                    v = max(v, low + (high - low) * (t - a + fade) / fade)
                if b < t < b + fade:
                    v = max(v, high - (high - low) * (t - b) / fade)
            return v
        fade = max(fade, 0.05)
        points = {0.0, 100.0}
        for a, b in windows:
            points |= {a - fade, a, b, b + fade}
        stops = [(p, round(value(p), 3)) for p in sorted(points) if 0 <= p <= 100]
        frames = "".join(f"{p:.2f}%{{opacity:{o}}}" for p, o in stops)
        if final is None:
            final = any(b >= 99 for _, b in windows)
        static = high if final else low
        self.rules.append(f"@keyframes {name}{{{frames}}}"
                          f".{name}{{opacity:{static};animation:{name} {self.duration}s linear infinite}}")
        return name

    def css(self):
        return "".join(self.rules)


BASE_CSS = """
text{font-family:U,-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;font-weight:500}
.w6{font-weight:600}.w7{font-weight:700}
.bar{transform-box:fill-box;transform-origin:center;animation:bar .9s ease-in-out infinite alternate}
@keyframes bar{0%{transform:scaleY(.3)}100%{transform:scaleY(1)}}
.spin{transform-box:fill-box;transform-origin:center;animation:spin .8s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.blink{animation:blink 1.05s steps(1) infinite}
@keyframes blink{0%{opacity:1}50%{opacity:0}}
@media (prefers-reduced-motion: reduce){*{animation:none!important}}
"""


def meter(x, y, n=7, h=14, gap=4.2, cls="f-action"):
    parts = []
    heights = [0.35, 0.7, 0.5, 1.0, 0.6, 0.85, 0.4, 0.75, 0.55]
    for i in range(n):
        bh = h * heights[i % len(heights)]
        delay = -(i * 0.37 % 0.9)
        dur = 0.55 + (i * 0.13 % 0.5)
        parts.append(f'<rect class="bar {cls}" style="animation-delay:{delay:.2f}s;animation-duration:{dur:.2f}s" '
                     f'x="{x + i * gap:.1f}" y="{y - bh / 2:.1f}" width="2" height="{bh:.1f}" rx="1"/>')
    return "".join(parts)


def window_controls(x, y):
    return (f'<circle class="f-err" cx="{x}" cy="{y}" r="6"/>'
            f'<circle class="f-orange" cx="{x + 20}" cy="{y}" r="6"/>'
            f'<circle class="f-ok" cx="{x + 40}" cy="{y}" r="6"/>')


MIC = ('<path d="M9.92 4.67C9.92 3.06 8.61 1.75 7 1.75S4.08 3.06 4.08 4.67v2.92C4.08 9.19 5.39 10.5 7 10.5s2.92-1.31 2.92-2.92V4.67Zm1.16 2.91c0 2.26-1.83 4.09-4.08 4.09S2.92 9.84 2.92 7.58V4.67C2.92 2.41 4.75.58 7 .58s4.08 1.83 4.08 4.09v2.91Z"/>'
       '<path d="M1.17 7.58V6.42a.58.58 0 0 1 1.16 0v1.16c0 2.58 2.09 4.67 4.67 4.67s4.67-2.09 4.67-4.67V6.42a.58.58 0 0 1 1.16 0v1.16c0 3.22-2.61 5.84-5.83 5.84S1.17 10.8 1.17 7.58Z"/>')


def svg(w, h, title, desc, style, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
            f'role="img" aria-labelledby="t d"><title id="t">{title}</title><desc id="d">{desc}</desc>'
            f'<style>{style}</style>{body}</svg>\n')


# ---------------------------------------------------------------- dictation
def dictation():
    W, H, T = 960, 520, 11
    A = Anim(T)
    line1 = "I'll send the cleanup notes this afternoon. The next review is"
    line2 = "tomorrow at ten, so tell me if anything is missing."
    texts = [line1, line2, "Mail", "File   Edit   View   Message", "Transcribe", "Sat 10 Oct   10:42",
             "Mail · New message", "To", "Aanu", "Subject", "Platform cleanup", "Hi Aanu,",
             "Transcribing", "Inserted", "Double-tap Option to start", "Speak", "Tap Option once to finish",
             "Pasted at your cursor", "⌥", "option"]

    wx, wy, ww, wh = 160, 76, 640, 320
    b = []
    b.append(f'<rect class="f-page" width="{W}" height="{H}" rx="16"/>')
    # menu bar
    b.append(f'<path class="f-surface" d="M16 0h{W - 32}a16 16 0 0 1 16 16v20H0V16A16 16 0 0 1 16 0Z"/>')
    b.append('<text class="f-primary w7" x="16" y="23" font-size="13">Mail</text>'
             '<text class="f-body" x="54" y="23" font-size="13" xml:space="preserve">File   Edit   View   Message</text>')
    b.append(f'<g class="f-muted" transform="translate(724 11) scale(1)">{MIC}</g>'
             '<text class="f-body" x="744" y="23" font-size="13">Transcribe</text>'
             '<text class="f-body" x="830" y="23" font-size="13" xml:space="preserve">Sat 10 Oct   10:42</text>')
    # mail window
    b.append(f'<rect class="f-surface s-border" x="{wx}" y="{wy}" width="{ww}" height="{wh}" rx="14"/>')
    b.append(f'<path class="f-chrome" d="M{wx + 14} {wy + .5}h{ww - 28}a13.5 13.5 0 0 1 13.5 13.5V{wy + 44}H{wx + .5}V{wy + 14}a13.5 13.5 0 0 1 13.5-13.5Z"/>')
    b.append(window_controls(wx + 20, wy + 22))
    b.append(f'<text class="f-primary w6" x="{wx + ww / 2}" y="{wy + 27}" font-size="13" text-anchor="middle">Mail · New message</text>')
    b.append(f'<text class="f-muted" x="{wx + 24}" y="{wy + 81}" font-size="15">To</text>'
             f'<text class="f-body" x="{wx + 58}" y="{wy + 81}" font-size="15">Aanu</text>'
             f'<text class="f-muted" x="{wx + 24}" y="{wy + 117}" font-size="15">Subject</text>'
             f'<text class="f-body" x="{wx + 92}" y="{wy + 117}" font-size="15">Platform cleanup</text>'
             f'<rect class="f-border" x="{wx + 24}" y="{wy + 136}" width="{ww - 48}" height="1"/>'
             f'<text class="f-primary" x="{wx + 24}" y="{wy + 170}" font-size="16">Hi Aanu,</text>')
    ty = wy + 206
    # cursor before insertion, then dictated text with cursor after it
    c1 = A.show([(0, 67.5)], final=False, fade=0.2)
    b.append(f'<g class="{c1}"><rect class="blink f-primary" x="{wx + 24}" y="{ty - 14}" width="1.5" height="19"/></g>')
    t = A.show([(68, 97)], final=True, fade=0.3)
    b.append(f'<g class="{t}"><text class="f-primary" x="{wx + 24}" y="{ty}" font-size="16">{line1}</text>'
             f'<text class="f-primary" x="{wx + 24}" y="{ty + 26}" font-size="16">{line2}</text></g>')
    c2 = A.show([(68, 97)], final=True, fade=0.3)
    b.append(f'<g class="{c2}"><rect class="blink f-primary" x="{wx + 370}" y="{ty + 12}" width="1.5" height="19"/></g>')

    # chip
    cw, ch = 164, 34
    cx, cy = W / 2 - cw / 2, 448
    b.append(f'<g class="{A.show([(9.5, 97)], final=True, fade=0.8)}">'
             f'<rect x="{cx}" y="{cy + 3}" width="{cw}" height="{ch}" rx="17" fill="#002654" opacity=".08"/>'
             f'<rect class="f-surface s-border" x="{cx}" y="{cy}" width="{cw}" height="{ch}" rx="17"/></g>')
    mid = cy + ch / 2
    rec = A.show([(10, 55)], final=False, fade=0.5)
    timer = []
    for i, (a, z) in enumerate([(10, 19), (19, 28), (28, 37), (37, 46), (46, 55.5)]):
        timer.append(f'<text class="{A.show([(a, z)], final=False, fade=0)} f-muted w6" x="{cx + 86}" y="{mid + 4.5}" font-size="13">0:0{i}</text>')
    b.append(f'<g class="{rec}"><circle class="f-err" cx="{cx + 14}" cy="{mid}" r="3"/>'
             f'{meter(cx + 26, mid, n=8, h=15)}</g>{"".join(timer)}'
             f'<g class="{rec}"><circle class="f-subtle" cx="{cx + cw - 20}" cy="{mid}" r="12"/>'
             f'<rect class="s-body" fill="none" stroke-width="1" x="{cx + cw - 24.5}" y="{mid - 4.5}" width="9" height="9" rx="2"/></g>')
    tr = A.show([(55.5, 67.5)], final=False, fade=0.5)
    b.append(f'<g class="{tr}"><g class="spin"><circle class="s-border" fill="none" stroke-width="2" cx="{cx + 20}" cy="{mid}" r="6.5"/>'
             f'<path class="s-action" fill="none" stroke-width="2" stroke-linecap="round" d="M{cx + 20} {mid - 6.5}a6.5 6.5 0 0 1 6.5 6.5"/></g>'
             f'<text class="f-primary w6" x="{cx + 36}" y="{mid + 4.5}" font-size="13">Transcribing</text></g>')
    ins = A.show([(68, 97)], final=True, fade=0.5)
    b.append(f'<g class="{ins}"><circle class="f-ok" cx="{cx + 20}" cy="{mid}" r="7"/>'
             f'<path fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M{cx + 16.8} {mid}l2.2 2.2 4-4.4"/>'
             f'<text class="f-primary w6" x="{cx + 36}" y="{mid + 4.5}" font-size="13">Inserted</text>'
             f'<rect class="s-link s-action" fill="none" stroke-width="1.3" x="{cx + cw - 30}" y="{mid - 5}" width="8" height="10" rx="2"/>'
             f'<path class="s-action" fill="none" stroke-width="1.3" d="M{cx + cw - 27} {mid - 7}h6a2 2 0 0 1 2 2v7"/></g>')

    # option key + caption
    kx, ky = 160, 444
    b.append(f'<rect class="f-surface s-border" x="{kx}" y="{ky}" width="44" height="42" rx="8"/>')
    flash = A.show([(6.5, 7.5), (9, 10), (53.5, 54.5)], final=False, fade=0.6)
    b.append(f'<rect class="f-action {flash}" x="{kx}" y="{ky}" width="44" height="42" rx="8"/>')
    b.append(f'<text class="f-primary w6" x="{kx + 22}" y="{ky + 20}" font-size="15" text-anchor="middle">⌥</text>'
             f'<text class="f-muted" x="{kx + 22}" y="{ky + 34}" font-size="9" text-anchor="middle">option</text>')
    for txt, win in [("Double-tap Option to start", (0, 10)), ("Speak", (10.5, 53)),
                     ("Tap Option once to finish", (53.5, 67.5)), ("Pasted at your cursor", (68, 100))]:
        cls = A.show([win], fade=0.6)
        b.append(f'<text class="{cls} f-primary w6" x="{kx + 56}" y="{ky + 26}" font-size="14">{txt}</text>')

    style = font_face("".join(texts)) + palette_css() + BASE_CSS + A.css()
    return svg(W, H, "Dictation in Transcribe",
               "Double-tap Option, speak, tap Option again, and the text is pasted into the email at the cursor.",
               style, "".join(b))


# ---------------------------------------------------------------- meetings
def meetings():
    W, H, T = 960, 580, 15
    A = Anim(T)
    turns = [("You", "12:01", "Should dictation stay separate from meetings?", 12),
             ("System audio", "12:04", "Yes. Keep them as two modes.", 22),
             ("You", "12:10", "I'll send the cleanup notes this afternoon.", 32),
             ("System audio", "12:15", "Good. We review the rest tomorrow.", 42)]
    notes = [("Two modes, not one", 18), ("Ask about export folder", 36)]
    summary = ["Dictation and meetings stay separate. Cleanup notes go out",
               "this afternoon and the next review is tomorrow."]
    texts = [t[0] + t[1] + t[2] for t in turns] + [n[0] for n in notes] + summary + [
        "Transcribe · Meetings", "Transcribe", "Dictation", "Meetings", "Dictionary", "Settings",
        "Connected", "Platform review", "Recording · Online meeting", "Microphone", "Mac audio",
        "Finish", "My notes", "Live transcript", "Writing notes", "Today · 10:00–10:38 · Online meeting",
        "Summary", "Transcript", "Decisions", "Keep dictation and meeting recording as separate modes.",
        "View source · 12:04", "Next steps", "You · Send the cleanup notes this afternoon.",
        "Unassigned · Review the remaining items tomorrow.", "View source · 12:10", "Copy notes",
        "Record a call or a conversation", "Take notes while it transcribes", "Get notes linked to the transcript",
        "Edit", "Export"]

    wx, wy, ww, wh = 24, 24, 912, 488
    sb = 168
    b = []
    b.append(f'<rect class="f-canvas" width="{W}" height="{H}" rx="16"/>')
    b.append(f'<rect class="f-surface s-border" x="{wx}" y="{wy}" width="{ww}" height="{wh}" rx="14"/>')
    b.append(f'<clipPath id="win"><rect x="{wx}" y="{wy}" width="{ww}" height="{wh}" rx="14"/></clipPath><g clip-path="url(#win)">')
    b.append(f'<path class="f-chrome" d="M{wx + 14} {wy + .5}h{ww - 28}a13.5 13.5 0 0 1 13.5 13.5V{wy + 40}H{wx + .5}V{wy + 14}a13.5 13.5 0 0 1 13.5-13.5Z"/>')
    b.append(window_controls(wx + 20, wy + 20))
    b.append(f'<text class="f-primary w6" x="{wx + ww / 2}" y="{wy + 25}" font-size="13" text-anchor="middle">Transcribe · Meetings</text>')
    # sidebar
    sx, sy = wx + .5, wy + 40
    b.append(f'<rect class="f-page" x="{sx}" y="{sy}" width="{sb}" height="{wh - 41}"/>'
             '</g>')
    b.append(f'<text class="f-primary w7" x="{sx + 16}" y="{sy + 32}" font-size="17">Transcribe</text>')
    for i, item in enumerate(["Dictation", "Meetings", "Dictionary", "Settings"]):
        yy = sy + 50 + i * 40
        if item == "Meetings":
            b.append(f'<rect class="f-selected" x="{sx + 12}" y="{yy}" width="{sb - 24}" height="34" rx="8"/>')
        b.append(f'<text class="f-primary w6" x="{sx + 24}" y="{yy + 22}" font-size="14">{item}</text>')
    b.append(f'<circle class="s-muted" fill="none" stroke-width="1.2" cx="{sx + 22}" cy="{wy + wh - 22}" r="6"/>'
             f'<text class="f-muted" x="{sx + 34}" y="{wy + wh - 18}" font-size="12">Connected</text>')

    mx = wx + sb + 32
    mr = wx + ww - 32
    # ---- phase 1: live meeting
    live = A.show([(0, 60)], final=False, fade=1.2)
    p = [f'<g class="{live}">']
    p.append(f'<text class="f-primary w7" x="{mx}" y="{wy + 94}" font-size="28">Platform review</text>')
    p.append(f'<circle class="f-err" cx="{mx + 4}" cy="{wy + 120}" r="3.5"/>'
             f'<text class="f-body" x="{mx + 14}" y="{wy + 125}" font-size="13">Recording · Online meeting</text>')
    # sources
    for i, (label, wdt) in enumerate([("Microphone", 132), ("Mac audio", 120)]):
        px = mx + 190 + i * 146
        p.append(f'<rect class="f-subtle" x="{px}" y="{wy + 108}" width="{wdt}" height="24" rx="12"/>'
                 f'<text class="f-body" x="{px + 12}" y="{wy + 124}" font-size="12">{label}</text>'
                 f'{meter(px + wdt - 36, wy + 120, n=6, h=11, gap=4)}')
    p.append(f'<rect class="f-action" x="{mr - 80}" y="{wy + 70}" width="80" height="34" rx="17"/>'
             f'<text class="f-onaction w6" x="{mr - 40}" y="{wy + 92}" font-size="14" text-anchor="middle">Finish</text>')
    p.append(f'<rect class="f-primary {A.show([(57.5, 59.5)], final=False, fade=0.5, high=0.25)}" x="{mr - 80}" y="{wy + 70}" width="80" height="34" rx="17"/>')
    # columns
    nx, lx = mx, mx + 250
    p.append(f'<rect class="f-border" x="{mx}" y="{wy + 150}" width="{mr - mx}" height="1"/>')
    p.append(f'<text class="f-muted w6" x="{nx}" y="{wy + 180}" font-size="12" letter-spacing=".6">MY NOTES</text>'
             f'<text class="f-muted w6" x="{lx}" y="{wy + 180}" font-size="12" letter-spacing=".6">LIVE TRANSCRIPT</text>')
    p.append(f'<rect class="f-border" x="{lx - 24}" y="{wy + 166}" width="1" height="{wh - 190}"/>')
    for i, (txt, at) in enumerate(notes):
        cls = A.show([(at, 60)], final=False, fade=1)
        p.append(f'<g class="{cls}"><circle class="f-body" cx="{nx + 3}" cy="{wy + 207 + i * 30}" r="2"/>'
                 f'<text class="f-primary" x="{nx + 14}" y="{wy + 212 + i * 30}" font-size="15">{txt}</text></g>')
    pen = A.show([(14, 45)], final=False, fade=1)
    p.append(f'<rect class="blink f-primary {pen}" x="{nx}" y="{wy + 256}" width="1.5" height="18"/>')
    for i, (who, ts, txt, at) in enumerate(turns):
        cls = A.show([(at, 60)], final=False, fade=1.2)
        yy = wy + 210 + i * 56
        p.append(f'<g class="{cls}"><text class="f-muted w6" x="{lx}" y="{yy}" font-size="12">{who} · {ts}</text>'
                 f'<text class="f-primary" x="{lx}" y="{yy + 21}" font-size="15">{txt}</text></g>')
    p.append('</g>')
    b += p

    # ---- phase 2: processing
    proc = A.show([(61, 67)], final=False, fade=0.8)
    b.append(f'<g class="{proc}"><g class="spin"><circle class="s-border" fill="none" stroke-width="2.5" cx="{(mx + mr) / 2 - 62}" cy="{wy + 260}" r="9"/>'
             f'<path class="s-action" fill="none" stroke-width="2.5" stroke-linecap="round" d="M{(mx + mr) / 2 - 62} {wy + 251}a9 9 0 0 1 9 9"/></g>'
             f'<text class="f-primary w6" x="{(mx + mr) / 2 - 44}" y="{wy + 265}" font-size="15">Writing notes</text></g>')

    # ---- phase 3: summary
    done = A.show([(68, 99)], final=True, fade=1.2)
    q = [f'<g class="{done}">']
    q.append(f'<text class="f-primary w7" x="{mx}" y="{wy + 94}" font-size="28">Platform review</text>'
             f'<text class="f-muted" x="{mx}" y="{wy + 124}" font-size="13">Today · 10:00–10:38 · Online meeting</text>')
    q.append(f'<rect class="f-subtle" x="{mx}" y="{wy + 140}" width="84" height="30" rx="15"/>')
    for x, label in [(mx + 16, "Summary"), (mx + 106, "My notes"), (mx + 190, "Transcript")]:
        q.append(f'<text class="f-primary w6" x="{x}" y="{wy + 160}" font-size="13">{label}</text>')
    y = wy + 196
    for line in summary:
        q.append(f'<text class="f-body" x="{mx}" y="{y}" font-size="15">{line}</text>')
        y += 22
    def source(x, y, label):
        return (f'<rect class="s-border" fill="none" x="{x}" y="{y}" width="136" height="26" rx="13"/>'
                f'<text class="f-primary w6" x="{x + 68}" y="{y + 17}" font-size="12" text-anchor="middle">{label}</text>')
    q.append(f'<text class="f-primary w7" x="{mx}" y="{y + 22}" font-size="16">Decisions</text>'
             f'<text class="f-body" x="{mx}" y="{y + 48}" font-size="15">Keep dictation and meeting recording as separate modes.</text>'
             + source(mx, y + 60, "View source · 12:04"))
    y += 108
    q.append(f'<text class="f-primary w7" x="{mx}" y="{y}" font-size="16">Next steps</text>'
             f'<text class="f-body" x="{mx}" y="{y + 26}" font-size="15">You · Send the cleanup notes this afternoon.</text>'
             f'<text class="f-body" x="{mx}" y="{y + 48}" font-size="15">Unassigned · Review the remaining items tomorrow.</text>'
             + source(mx, y + 60, "View source · 12:10"))
    y += 96
    q.append(f'<rect class="f-action" x="{mx}" y="{y}" width="102" height="34" rx="17"/>'
             f'<text class="f-onaction w6" x="{mx + 51}" y="{y + 22}" font-size="13" text-anchor="middle">Copy notes</text>'
             f'<rect class="s-border f-surface" x="{mx + 112}" y="{y}" width="56" height="34" rx="17"/>'
             f'<text class="f-primary w6" x="{mx + 140}" y="{y + 22}" font-size="13" text-anchor="middle">Edit</text>'
             f'<text class="f-primary w6" x="{mx + 194}" y="{y + 22}" font-size="13">Export</text>')
    q.append('</g>')
    b += q

    # steps under the window
    steps = [("Record a call or a conversation", (0, 14)), ("Take notes while it transcribes", (14, 60)),
             ("Get notes linked to the transcript", (60, 100))]
    for i, (label, win) in enumerate(steps):
        x = W / 2 + (i - 1) * 300
        cls = A.show([win], fade=1, low=0.35)
        b.append(f'<g class="{cls}"><circle class="f-action" cx="{x - 110}" cy="{H - 34}" r="10"/>'
                 f'<text class="f-onaction w7" x="{x - 110}" y="{H - 29.5}" font-size="12" text-anchor="middle">{i + 1}</text>'
                 f'<text class="f-primary w6" x="{x - 94}" y="{H - 29}" font-size="14">{label}</text></g>')

    style = font_face("".join(texts) + "123") + palette_css() + BASE_CSS + A.css()
    return svg(W, H, "Meetings in Transcribe",
               "Transcribe records a meeting, shows a live transcript beside your own notes, then writes a summary with decisions and next steps linked to the transcript.",
               style, "".join(b))


for name, fn in [("dictation", dictation), ("meetings", meetings)]:
    data = fn()
    with open(f"{OUT}/{name}.svg", "w") as f:
        f.write(data)
    print(name, len(data) // 1024, "KB")
