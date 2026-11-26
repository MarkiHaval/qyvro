# Qyvro

![Qyvro Studio V4](docs/hero-v4.png)

A native macOS file explorer built for people who work with large volumes of images and video — generative art, editing, color grading, and design.

**Finder** answers *"where does this file live?"*
**Qyvro** answers *"which of these 1,500 frames do I actually need — and what do I do with it next?"*

> **macOS 13+** · **Universal (Apple Silicon & Intel)** · **Pure AppKit** (zero third-party dependencies) · **MIT License** · [Releases](../../releases) · [Build from source](#build-from-source)

---

## Why Qyvro instead of Finder

Finder was designed for documents. Once a folder holds 1,500 twenty-megabyte stills or ProRes clips, it falls apart: thumbnails stay tiny, resolutions and durations are hidden, and culling a shoot turns into an endless loop of open, close, squint, and drag.

Qyvro is engineered specifically for heavy visual folders — native AppKit, Display P3 color accuracy, hardware-accelerated transitions, and zero lag.

---

## Key Capabilities

### Studio V4 Workspace & Customizable Look

- **4 switchable window layouts (`⌃⌘L`)**: **Studio · Island (V4)** (frameless floating canvas with unified hero header and recessed filter tray), **Podium · Bottom Dock**, **Edge Rail**, and **Classic Sidebar**.
- **17 built-in themes**: Ships by default in **Aurora · Horizon (V3)** (warm obsidian glass with sunset amber atmosphere), alongside Studio V4 (*Titanium*, *Noir Amber*, *Malachite*), Aurora & Vision Glass V3, and Classic palettes. Full live controls for surface opacity, colors, grid density, and gesture sensitivity.
- **3 minimalist 2-plane folder styles**: *Graphite + Spine*, *Dark Satin*, and *Swiss Seam* — plus custom per-folder colors, Finder tags, and editorial typography (`Avenir Next` + tabular `SF Mono`).
- **Per-folder view & sort profiles**: Independently remembers thumbnail scale, grid/list mode, and sort order for each folder you customize.

### Visual Grid Built for Media

- **Resolution, duration & file size right under every tile**: `5504×3072 · 18.4 MB`, `3840×2160 · 0:24 · 64.2 MB` — no Get Info window needed.
- **Continuous zoom**: Pinch on the trackpad or `Ctrl + scroll` to smoothly scale from dense rows to full gallery tiles.
- **Date grouping with horizontal carousels**: *Today*, *Yesterday*, *Previous 7 Days*, and monthly groups. Scroll collapsed rows sideways with `Shift + scroll` without expanding the entire section.
- **Version stacking**: Collapses an original, its resized copy, JPEG export, and browser duplicates into a single stack with a count badge. Click to expand.
- **Multi-select floating action bar & Undo toasts**: Batch actions appear right where you work, with non-blocking glass Undo banners (`⌘Z`).

---

![Built-in Media Viewer, Drop Shelf, Layouts & Folder Styles](docs/features-v4.png)

### Cull Hundreds of Frames in Minutes

- **Built-in viewer (`Space`)**: Instant full-resolution preview with arrow-key browsing. Video and audio autoplay immediately and remember your volume/mute state.
- **Side-by-side comparison (`C`)** & **Split Wipe curtain (`V`)**: Compare 2–3 frames next to each other, or overlay two images with an interactive draggable split divider to inspect grades, crops, and upscales.
- **Two-stage native Finder marking (`F`)**: Cycles through *Candidate* (pink corner dot) → *Picked* (green dot) → clear. Stored as real macOS Finder tags inside file extended attributes — survives renames, moves, and Spotlight searches. Also clickable directly on thumbnail corners.
- **Drop Shelf (`⌥⌘S`)**: A floating staging tray to gather files from multiple folders, preview the selection, and move, copy, or batch-drag everything out into Figma, a browser, or another folder (hold `⌥` while dragging to export compressed JPEGs on the fly).

---

![Disk Analyzer & SHA-256 Duplicates, Studio Batch Rename, Inspector & Cloud Clipboard](docs/tools-v4.png)

### Built-In Pro File Tools

- **Disk Analyzer & SHA-256 Duplicate Finder (`⌥⌘D`)**: Interactive storage ring in the toolbar opens a 3-tab deep scanner — **Folders** (recursive size bars), **Largest Files** (top 150 heaviest files), and **Duplicates (SHA-256)** (3-stage CryptoKit size → prefix → full SHA-256 verification with 1-click safe cleanup that preserves the oldest original).
- **Studio Batch Rename (`⌘⇧R`)**: Dedicated batch-rename window with live *Before → After* preview across 4 modes — **Replace**, **Template** (`{name}`, `{n}`, `{01}`, `{001}`, `{date}`), **Prefix / Suffix**, and **Case / Cleanup** — fully undoable with `⌘Z`.
- **On-the-fly media prep**: Parallelized context-menu resize (`5999 / 4096 / 2560 / 2048 / 1024` + custom), `⌥ + Drag` instant JPEG export (≤5999 px, ≤20 MB) for any drop target, `HEIC → PNG` and `PNG → JPEG` conversion, ZIP/Unzip, SHA-256 checksums, and type-aware *Open in Photoshop / Premiere Pro*.
- **Preview & Inspector Sidebar (`⌥⌘P`)**: Live media specs, auto recursive folder size calculation, Finder tags, and per-folder color swatches.
- **Clipboard History & Cross-Device Cloud Sync (`⌃⌘V`)**: Local history of copied text, links, and images, plus an optional self-hosted sync daemon ([tools/clipsync](tools/clipsync/README.md)) for macOS, Windows, and iPhone over Tailscale Funnel (automatically skips password-manager secrets).

### Navigation & Speed

- **Two-finger swipe Back / Forward** with a hardware-accelerated Display P3 wave transition (zero color shift or flash).
- **Command Palette (`⌘K`)**: Keyboard-first launcher (`↑`/`↓`/`Enter`/`Esc`) for actions, layouts, themes, folder styles, and tools.
- **Split Panes (`⌘D`), Tabs (`⌘T`, `⌘1`–`⌘9`, `⌘⇧T`), Bookmarks & Saved Tab Groups**.
- **Folder & Mac Spotlight Search (`⌘F`)** with system-junk filtering.
- **Global Summon (`⌘E`)**: Bring Qyvro above any app from anywhere, press again to hide.

---

## Keyboard Shortcuts

### Explorer

| Shortcut | Action |
|---|---|
| `Space` | Open built-in media viewer |
| `⌘E` | Global summon / hide Qyvro |
| `⌘K` | Command Palette |
| `⌥⌘S` | Toggle Drop Shelf |
| `⌥⌘D` | Disk Analyzer & SHA-256 Duplicates |
| `⌥⌘P` | Toggle Preview & Inspector Sidebar |
| `⌃⌘L` | Cycle window layout (Studio / Podium / Rail / Sidebar) |
| `⌘⇧R` | Studio Batch Rename |
| `⌘R` | Refresh current folder |
| `⌃⌘R` | Reveal selection in Finder |
| `⌘D` | Split pane |
| `⌘F` | Focus search (Folder / Mac Spotlight) |
| `⌘Z` / `⌘⇧Z` | Undo / Redo file operations |
| `⌘⌫` | Move selection to Trash |
| `⌘↑` / `⌘←` / `⌘→` | Parent folder / Back / Forward |
| `Shift + scroll` | Scroll collapsed date row horizontally |
| `Ctrl + scroll` / Pinch | Scale thumbnail size continuously |
| `⌥ + drag` | Export ready-to-share JPEG (≤5999 px, ≤20 MB) |
| `⌃⌘V` | Paste from cross-device Cloud Clipboard (when configured) |

### Built-in Viewer

| Key | Action |
|---|---|
| `←` `→` | Previous / next file |
| `F` | Cycle two-stage Finder mark (Candidate → Picked → Clear) |
| `C` | Side-by-side comparison (2–3 frames) |
| `V` | Interactive split wipe curtain |
| `S` / `M` | Play / Pause video & audio · Mute / Unmute |
| `⌫` | Move to Trash and advance to next frame |
| `T` / `Esc` | Toggle fullscreen · Close viewer |

---

## Build from Source

Pure Swift & AppKit compiled directly with `swiftc` — no Xcode project, no SwiftPM, no external dependencies.

```bash
git clone https://github.com/MarkiHaval/qyvro.git
cd qyvro
./build_app.sh
```

**Requirements:** macOS 13+ with Xcode Command Line Tools (`xcode-select --install`).
`build_app.sh` compiles `arm64` and `x86_64` in parallel, merges them into a Universal binary via `lipo`, ad-hoc signs the bundle, and prints the path to the built `Qyvro.app` (drag or copy it into `/Applications`).

### First Launch Note

Because Qyvro is distributed outside the Mac App Store without Apple notarization, macOS Gatekeeper may warn on first launch if downloaded as a prebuilt archive:

1. Right-click `Qyvro.app` → **Open** → click **Open** again.
2. If blocked, go to **System Settings → Privacy & Security** and click **Open Anyway**.

This is only required once.

---

## License

MIT — see [LICENSE](LICENSE).
