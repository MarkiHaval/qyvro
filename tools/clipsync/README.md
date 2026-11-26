# Qyvro Cloud Clipboard Sync

Optional self-hosted companion for sharing the most recent copied item (text or image) across macOS, Windows, and iPhone.

## Components

- **`qyvro_clip.py serve`** — Runs a local HTTP server on `127.0.0.1:27140`, designed to be exposed via Tailscale Funnel at `/clip`.
- **`qyvro_clip.py client`** — Windows background client: uploads copied items to the server and pastes the shared item with `Ctrl+Alt+V` (requires `Pillow`).
- **`install-windows.ps1`** — Registers autostart tasks for the server and Windows client in Windows Task Scheduler.
- **macOS (built into Qyvro)** — `Sources/CloudClipboardSync.swift` automatically activates when `~/Library/Application Support/QyvroClipboard/cloud.json` exists:
  ```json
  {
    "url": "https://<your-host>/clip",
    "token": "<shared-secret>",
    "device": "mac-1"
  }
  ```
  Press `⌃⌘V` anywhere on macOS to paste the latest shared cloud item (requires macOS Accessibility permission for Qyvro).
- **iPhone (Apple Shortcuts)** — Uses `GET /clip/data?k=<token>` and `POST /clip/push?source=iphone&k=<token>`.

## Security & Privacy

- Tokens live strictly in local `token.txt` (server) and `cloud.json` (clients) and are excluded by `.gitignore`.
- Local Finder file references and items marked as concealed/transient by password managers are never uploaded.
- Your local clipboard is never overwritten by remote changes: pasting via `⌃⌘V` (macOS) or `Ctrl+Alt+V` (Windows) temporarily swaps in the shared item, triggers paste, and restores your local clipboard immediately.
