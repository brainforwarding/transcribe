# Transcribe native design resources

Urbanist Regular, Medium, SemiBold and ExtraBold come from the local Circles frontend's existing `src/app/fonts/og` assets. Bold comes from the upstream Urbanist project, https://github.com/coreyhu/Urbanist/blob/main/fonts/otf/Urbanist-Bold.otf. The accompanying SIL Open Font License covers these faces.

Icons are exact original SVG exports from approved Figma file `501FiwrHn8ZJlwbgzjTDly`, chip node `3:2047` and Proposal A nodes `5:1729` and `6:1419`, with their scene-prefixed exported names retained. AppKit does not decode these SVGs directly, so matching PDF derivatives are vector renderings made by WebKit at each original SVG viewport. No icon paths were reconstructed or substituted. Template rendering applies semantic Circles colors. Native macOS traffic lights replace the exported mock window controls.

Tokens in DesignSystem.swift correspond to Circles Design System 2026 v2.8.7's complete token export, `docs/Circles/figma-design-system-2026/tokens/figma-export-2026-10-04-v2.8.7.json`. Later v2.8.9 adds scheduling components and does not change these tokens.
