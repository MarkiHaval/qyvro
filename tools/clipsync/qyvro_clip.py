"""Общий буфер Qyvro: сервер (один последний элемент) и клиент буфера Windows.

    python qyvro_clip.py serve    # сервер на 127.0.0.1:27140, наружу через Tailscale Funnel /clip
    python qyvro_clip.py client   # буфер Windows: копирование уходит на сервер, Ctrl+Alt+V вставляет общий

Ключ лежит в token.txt рядом со скриптом. Только стандартная библиотека,
клиенту Windows для картинок нужен Pillow.
"""

import hashlib
import hmac
import io
import json
import logging
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE, "data")
PORT = 27140
MAX_BYTES = 40 * 1024 * 1024
WAIT_MAX = 25

logging.basicConfig(
    filename=os.path.join(BASE, "qyvro_clip.log"),
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("clip")


def read_token():
    with open(os.path.join(BASE, "token.txt"), encoding="utf-8") as f:
        return f.read().strip()


def sniff(body):
    if body.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image", "image/png"
    if body[:3] == b"\xff\xd8\xff":
        return "image", "image/jpeg"
    if body[:6] in (b"GIF87a", b"GIF89a"):
        return "image", "image/gif"
    if body[4:8] == b"ftyp" and body[8:12] in (b"heic", b"heix", b"mif1", b"msf1", b"hevc"):
        return "image", "image/heic"
    return "text", "text/plain; charset=utf-8"


_RTF_SKIP = {
    "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer",
    "expandedcolortbl", "listtable", "listoverridetable", "generator", "themedata",
    "colorschememapping", "datastore", "latentstyles", "xmlnstbl", "rsidtbl",
}
_RTF_CHARS = {"par": "\n", "line": "\n", "tab": "\t", "emdash": "\u2014", "endash": "\u2013",
              "lquote": "\u2018", "rquote": "\u2019", "ldblquote": "\u201c",
              "rdblquote": "\u201d", "bullet": "\u2022", "~": "\u00a0", "-": "", "_": "\u2011"}


def rtf_to_text(rtf):
    """Обычный текст из RTF: быстрая команда айфона шлёт форматированный текст как RTF."""
    import re
    out, stack = [], []
    skip, uc, pending_skip = False, 1, 0
    codepage = "cp1252"
    m = re.search(r"\\ansicpg(\d+)", rtf)
    if m:
        codepage = "cp" + m.group(1)
    token = re.compile(r"\\([a-zA-Z]+)(-?\d+)? ?|\\'([0-9a-fA-F]{2})|\\([^a-zA-Z])|([{}])|(\r\n|\r|\n)|([^\\{}\r\n]+)")
    for word, arg, hexcode, sym, brace, newline, text in token.findall(rtf):
        if brace == "{":
            stack.append((skip, uc))
        elif brace == "}":
            if stack:
                skip, uc = stack.pop()
        elif newline:
            continue
        elif sym:
            if sym == "*":
                skip = True
            elif sym in "\r\n" and not skip:
                out.append("\n")
            elif sym in _RTF_CHARS and not skip:
                out.append(_RTF_CHARS[sym])
            elif sym in "\\{}" and not skip:
                out.append(sym)
        elif word:
            if word in _RTF_SKIP:
                skip = True
            elif word == "uc":
                uc = int(arg or 1)
            elif word == "u" and not skip:
                n = int(arg)
                out.append(chr(n + 65536 if n < 0 else n))
                pending_skip = uc
            elif word in _RTF_CHARS and not skip:
                out.append(_RTF_CHARS[word])
        elif hexcode:
            if pending_skip:
                pending_skip -= 1
            elif not skip:
                out.append(bytes([int(hexcode, 16)]).decode(codepage, "replace"))
        elif text:
            if pending_skip:
                drop = min(pending_skip, len(text))
                text, pending_skip = text[drop:], pending_skip - drop
            if not skip:
                out.append(text)
    # Эмодзи в RTF идут парой суррогатов \uN\uN: склеиваем их обратно.
    joined = "".join(out).encode("utf-16", "surrogatepass").decode("utf-16", "replace")
    return joined.strip()


# ---------------------------------------------------------------- сервер

class State:
    def __init__(self):
        os.makedirs(DATA_DIR, exist_ok=True)
        self.cv = threading.Condition()
        self.meta = None
        self.body = b""
        try:
            with open(os.path.join(DATA_DIR, "current.json"), encoding="utf-8") as f:
                meta = json.load(f)
            with open(os.path.join(DATA_DIR, "current.bin"), "rb") as f:
                body = f.read()
            if hashlib.sha256(body).hexdigest() == meta.get("sha"):
                self.meta, self.body = meta, body
        except (OSError, ValueError):
            pass

    def put(self, body, source):
        kind, mime = sniff(body)
        if kind == "text":
            try:
                text = body.decode("utf-8")
            except UnicodeDecodeError:
                raise ValueError("text must be utf-8")
            if text.lstrip().startswith("{\\rtf"):
                text = rtf_to_text(text)
                body = text.encode("utf-8")
            if not text.strip():
                raise ValueError("empty text")
        sha = hashlib.sha256(body).hexdigest()
        with self.cv:
            if self.meta and self.meta["sha"] == sha:
                return self.meta, False
            meta = {
                "id": secrets.token_hex(8),
                "kind": kind,
                "mime": mime,
                "sha": sha,
                "size": len(body),
                "source": source[:40],
                "ts": time.time(),
            }
            self.meta, self.body = meta, body
            self.cv.notify_all()
        # На диск только чтобы пережить перезапуск; отдаём всегда из памяти.
        try:
            for name, payload, mode in (
                ("current.bin", body, "wb"),
                ("current.json", json.dumps(meta).encode("utf-8"), "wb"),
            ):
                tmp = os.path.join(DATA_DIR, name + ".tmp")
                with open(tmp, mode) as f:
                    f.write(payload)
                os.replace(tmp, os.path.join(DATA_DIR, name))
        except OSError as e:
            log.warning("persist failed: %s", e)
        return meta, True

    def wait(self, since, timeout):
        with self.cv:
            self.cv.wait_for(
                lambda: self.meta is not None and self.meta["id"] != since, timeout
            )
            return self.meta, self.body


class Handler(BaseHTTPRequestHandler):
    server_version = "QyvroClip/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _route(self):
        url = urlparse(self.path)
        path = url.path
        if path.startswith("/clip"):
            path = path[len("/clip"):]
        return path.rstrip("/") or "/", parse_qs(url.query)

    def _authed(self):
        token = self.server.token
        got = self.headers.get("Authorization", "")
        if got.startswith("Bearer "):
            got = got[7:]
        else:
            # Быстрым командам айфона проще ключ в ссылке: ...?k=ключ
            got = self.headers.get("X-Clip-Key") or (self._route()[1].get("k") or [""])[0]
        return hmac.compare_digest(got.strip().encode(), token.encode())

    def _send(self, code, body=b"", ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode("utf-8"))

    def _once(self, name):
        # Временная раздача файла (например, быстрой команды для айфона):
        # data/once/<длинный случайный код>/<файл>, живёт 30 минут.
        if len(name) < 24 or not name.replace("-", "").replace("_", "").isalnum():
            return self._json(404, {"error": "not found"})
        folder = os.path.join(DATA_DIR, "once", name)
        try:
            files = os.listdir(folder)
            fpath = os.path.join(folder, files[0])
            if time.time() - os.path.getmtime(fpath) > 1800:
                return self._json(410, {"error": "expired"})
            with open(fpath, "rb") as f:
                body = f.read()
        except (OSError, IndexError):
            return self._json(404, {"error": "not found"})
        from urllib.parse import quote
        return self._send(200, body, "application/octet-stream", {
            "Content-Disposition": "attachment; filename*=UTF-8''" + quote(files[0])})

    def do_GET(self):
        path, q = self._route()
        if path == "/health":
            return self._send(200, b"ok", "text/plain")
        if path.startswith("/once/"):
            return self._once(path[len("/once/"):])
        if not self._authed():
            return self._json(401, {"error": "unauthorized"})
        state = self.server.state
        if path == "/meta":
            since = (q.get("since") or [""])[0]
            try:
                wait = min(float((q.get("wait") or ["0"])[0]), WAIT_MAX)
            except ValueError:
                wait = 0
            meta, _ = state.wait(since, wait) if wait > 0 else (state.meta, None)
            return self._json(200, meta or {})
        if path in ("/data", "/"):
            meta, body = state.meta, state.body
            if not meta:
                return self._send(204)
            # Текст для быстрой команды айфона отдаём как text/plain,
            # картинку с её типом, чтобы «Скопировать в буфер» понял её.
            return self._send(
                200, body, meta["mime"],
                {"X-Clip-Id": meta["id"], "X-Clip-Sha": meta["sha"],
                 "X-Clip-Kind": meta["kind"]},
            )
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        path, q = self._route()
        if not self._authed():
            return self._json(401, {"error": "unauthorized"})
        if path not in ("/push", "/"):
            return self._json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BYTES:
            return self._json(413, {"error": "bad size"})
        body = self.rfile.read(length)
        source = (q.get("source") or ["unknown"])[0]
        try:
            meta, fresh = self.server.state.put(body, source)
        except ValueError as e:
            return self._json(415, {"error": str(e)})
        if fresh:
            log.info("push %s %s %d bytes from %s", meta["id"], meta["kind"], meta["size"], source)
        return self._json(200, meta)


def serve():
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    httpd.daemon_threads = True
    httpd.token = read_token()
    httpd.state = State()
    log.info("serving on 127.0.0.1:%d", PORT)
    httpd.serve_forever()


# ---------------------------------------------------------------- клиент Windows

def client():
    import ctypes
    from ctypes import wintypes

    from PIL import Image, ImageGrab

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.OpenClipboard.restype = wintypes.BOOL
    user32.CloseClipboard.restype = wintypes.BOOL
    user32.EmptyClipboard.restype = wintypes.BOOL
    user32.GetClipboardData.argtypes = [wintypes.UINT]
    user32.GetClipboardData.restype = wintypes.HANDLE
    user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    user32.SetClipboardData.restype = wintypes.HANDLE
    user32.IsClipboardFormatAvailable.argtypes = [wintypes.UINT]
    user32.IsClipboardFormatAvailable.restype = wintypes.BOOL
    user32.GetClipboardSequenceNumber.restype = wintypes.DWORD
    user32.RegisterClipboardFormatW.argtypes = [wintypes.LPCWSTR]
    user32.RegisterClipboardFormatW.restype = wintypes.UINT
    kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
    kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalLock.restype = wintypes.LPVOID
    kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalFree.argtypes = [wintypes.HGLOBAL]

    CF_UNICODETEXT, CF_DIB, CF_HDROP = 13, 8, 15
    GMEM_MOVEABLE = 0x0002
    CF_PNG = user32.RegisterClipboardFormatW("PNG")
    # Менеджеры паролей помечают секреты этими форматами: такое не отправляем.
    SECRET_FORMATS = [
        user32.RegisterClipboardFormatW(n)
        for n in ("ExcludeClipboardContentFromMonitorProcessing",
                  "Clipboard Viewer Ignore")
    ]

    token = read_token()
    base = "http://127.0.0.1:%d" % PORT
    device = "windows"
    lock = threading.Lock()
    st = {"sha": None, "id": None, "ignore_until": 0.0}

    def request(method, path, body=None, timeout=10):
        req = urllib.request.Request(base + path, data=body, method=method)
        req.add_header("Authorization", "Bearer " + token)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(), r.headers

    def open_cb():
        for _ in range(20):
            if user32.OpenClipboard(None):
                return True
            time.sleep(0.05)
        return False

    def read_payload():
        if any(user32.IsClipboardFormatAvailable(f) for f in SECRET_FORMATS):
            return None
        if user32.IsClipboardFormatAvailable(CF_HDROP):
            return None
        if user32.IsClipboardFormatAvailable(CF_UNICODETEXT):
            if not open_cb():
                return None
            try:
                h = user32.GetClipboardData(CF_UNICODETEXT)
                if not h:
                    return None
                p = kernel32.GlobalLock(h)
                try:
                    text = ctypes.wstring_at(p)
                finally:
                    kernel32.GlobalUnlock(h)
            finally:
                user32.CloseClipboard()
            return text.encode("utf-8") if text.strip() else None
        if user32.IsClipboardFormatAvailable(CF_PNG):
            if open_cb():
                try:
                    h = user32.GetClipboardData(CF_PNG)
                    if h:
                        size = kernel32.GlobalSize(h) if hasattr(kernel32, "GlobalSize") else 0
                        p = kernel32.GlobalLock(h)
                        try:
                            if size:
                                return ctypes.string_at(p, size)
                        finally:
                            kernel32.GlobalUnlock(h)
                finally:
                    user32.CloseClipboard()
        if user32.IsClipboardFormatAvailable(CF_DIB):
            img = ImageGrab.grabclipboard()
            if isinstance(img, Image.Image):
                buf = io.BytesIO()
                img.save(buf, "PNG")
                return buf.getvalue()
        return None

    kernel32.GlobalSize.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalSize.restype = ctypes.c_size_t

    def put_global(fmt, data):
        h = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
        p = kernel32.GlobalLock(h)
        ctypes.memmove(p, data, len(data))
        kernel32.GlobalUnlock(h)
        if not user32.SetClipboardData(fmt, h):
            kernel32.GlobalFree(h)

    def write_clipboard(kind, body):
        if kind == "text":
            blobs = [(CF_UNICODETEXT, body.decode("utf-8").encode("utf-16-le") + b"\0\0")]
        else:
            try:
                img = Image.open(io.BytesIO(body))
                img.load()
            except Exception as e:  # HEIC и прочее, что Pillow не знает
                log.info("skip image: %s", e)
                return False
            bmp = io.BytesIO()
            img.convert("RGB").save(bmp, "BMP")
            png = io.BytesIO()
            img.save(png, "PNG")
            blobs = [(CF_DIB, bmp.getvalue()[14:]), (CF_PNG, png.getvalue())]
        if not open_cb():
            return False
        try:
            user32.EmptyClipboard()
            for fmt, data in blobs:
                put_global(fmt, data)
        finally:
            user32.CloseClipboard()
        return True

    # Вставка из общего буфера по Ctrl+Alt+V. Свой буфер не перетираем:
    # кладём элемент с сервера, жмём Ctrl+V за человека, возвращаем прежнее.
    MOD_ALT, MOD_CONTROL, MOD_NOREPEAT = 0x0001, 0x0002, 0x4000
    VK_V, VK_SHIFT, VK_CONTROL, VK_MENU = 0x56, 0x10, 0x11, 0x12
    WM_HOTKEY, KEYEVENTF_KEYUP = 0x0312, 0x0002
    user32.RegisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int, wintypes.UINT, wintypes.UINT]
    user32.RegisterHotKey.restype = wintypes.BOOL
    user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
    user32.GetAsyncKeyState.restype = ctypes.c_short
    user32.keybd_event.argtypes = [wintypes.BYTE, wintypes.BYTE, wintypes.DWORD, ctypes.c_size_t]
    busy = threading.Event()

    def paste_shared():
        try:
            code, body, headers = request("GET", "/data", timeout=20)
            if code != 200 or not body:
                return
            kind = headers.get("X-Clip-Kind") or sniff(body)[0]
            try:
                saved = read_payload()
            except Exception:
                saved = None
            with lock:
                st["ignore_until"] = time.time() + 3.0
                if not write_clipboard(kind, body):
                    return
            # Ctrl и Alt ещё зажаты: ждём, пока отпустят, иначе уйдёт Ctrl+Alt+V.
            deadline = time.time() + 1.5
            while time.time() < deadline and any(
                    user32.GetAsyncKeyState(k) & 0x8000 for k in (VK_CONTROL, VK_MENU, VK_SHIFT)):
                time.sleep(0.02)
            user32.keybd_event(VK_CONTROL, 0, 0, 0)
            user32.keybd_event(VK_V, 0, 0, 0)
            user32.keybd_event(VK_V, 0, KEYEVENTF_KEYUP, 0)
            user32.keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)
            time.sleep(0.6)
            if saved:
                with lock:
                    st["ignore_until"] = time.time() + 1.5
                    write_clipboard(sniff(saved)[0], saved)
            log.info("pasted shared %s", kind)
        except Exception as e:
            log.info("paste error: %s", e)
        finally:
            busy.clear()

    def hotkey_loop():
        if not user32.RegisterHotKey(None, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_V):
            log.warning("Ctrl+Alt+V is taken by another program (error %s)", ctypes.get_last_error())
            return
        log.info("Ctrl+Alt+V registered")
        msg = wintypes.MSG()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            if msg.message == WM_HOTKEY and not busy.is_set():
                busy.set()
                threading.Thread(target=paste_shared, daemon=True).start()

    threading.Thread(target=hotkey_loop, daemon=True).start()
    last_seq = user32.GetClipboardSequenceNumber()
    log.info("client started")
    while True:
        time.sleep(0.4)
        seq = user32.GetClipboardSequenceNumber()
        if seq == last_seq:
            continue
        last_seq = seq
        if time.time() < st["ignore_until"]:
            continue
        time.sleep(0.15)
        try:
            payload = read_payload()
        except Exception as e:
            log.info("read error: %s", e)
            continue
        if not payload or len(payload) > MAX_BYTES:
            continue
        sha = hashlib.sha256(payload).hexdigest()
        with lock:
            if sha == st["sha"]:
                continue
            st["sha"] = sha
        try:
            _, raw, _ = request("POST", "/push?source=" + device, payload, timeout=60)
            meta = json.loads(raw)
            with lock:
                st["id"] = meta.get("id", st["id"])
        except Exception as e:
            log.info("push error: %s", e)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "serve"
    try:
        serve() if mode == "serve" else client()
    except Exception:
        log.exception("crashed")
        raise
