# Общий буфер Qyvro

Один последний скопированный элемент (текст или картинка) общий для Маков, Windows и iPhone.

- `qyvro_clip.py serve` — сервер на `127.0.0.1:27140`. Наружу публикуется через Tailscale Funnel по пути `/clip`.
- `qyvro_clip.py client` — синхронизация буфера Windows (нужен Pillow).
- `install-windows.ps1` — автозапуск сервера и клиента через Планировщик заданий.
- Маки: Qyvro (`Sources/CloudClipboardSync.swift`) включает синхронизацию, если есть
  `~/Library/Application Support/QyvroClipboard/cloud.json`:
  `{"url": "https://<сервер>/clip", "token": "<ключ>", "device": "mac-1"}`.
- iPhone: быстрые команды, `GET /clip/data?k=<ключ>` и `POST /clip/push?source=iphone&k=<ключ>`.

Ключ лежит в `token.txt` рядом с сервером и в `cloud.json` на устройствах. В репозиторий он не попадает.
Файлы из Finder и секреты, помеченные менеджерами паролей, не синхронизируются.
