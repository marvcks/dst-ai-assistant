#!/usr/bin/env python3
"""Local companion service for the DST AI Assistant mod.

The HTTP server binds to loopback by default. It stores the LLM credential in
a mode-0600 JSON file and never returns the credential through its API.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import socketserver
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


LOG = logging.getLogger("dst-ai-service")
DEFAULT_BASE_URL = "https://api.deepseek.com"
DEFAULT_MODEL = "deepseek-chat"
SYSTEM_PROMPT = """你是《饥荒联机版》的游戏内 AI 问答助手。
请使用简短、明确的中文回答。不要使用 Markdown、项目符号、表格、标题或换行。
用户问题附带一份刚从服务器采集的游戏状态 JSON；涉及当前天数、季节、玩家状态、背包、Boss、猎犬或基地时，只能依据该 JSON 回答。数据缺失时明确说无法获取，不得编造。
可以回答一般玩法、物品、生物和机制问题，但不得声称已经执行游戏操作。
不得输出用户 ID、API key、密码或令牌。"""


class ServiceError(RuntimeError):
    """A user-facing service error with an HTTP status."""

    def __init__(self, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.status = status


class ConfigStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = threading.RLock()
        self.data: dict[str, str] = {
            "base_url": DEFAULT_BASE_URL,
            "model": DEFAULT_MODEL,
            "api_key": "",
        }
        self._load()

    def _load(self) -> None:
        with self.lock:
            if not self.path.exists():
                return
            try:
                loaded = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise RuntimeError(f"cannot read config file {self.path}: {exc}") from exc
            if isinstance(loaded, dict):
                for key in self.data:
                    if isinstance(loaded.get(key), str):
                        self.data[key] = loaded[key]

    @staticmethod
    def _validate_base_url(value: str) -> str:
        value = value.strip().rstrip("/")
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ServiceError("base_url 必须是有效的 http(s) URL")
        if parsed.username or parsed.password:
            raise ServiceError("base_url 不允许包含用户名或密码")
        if len(value) > 500:
            raise ServiceError("base_url 过长")
        return value

    @staticmethod
    def _validate_model(value: str) -> str:
        value = value.strip()
        if not value or len(value) > 200 or any(ord(ch) < 32 for ch in value):
            raise ServiceError("model 不能为空且长度不能超过 200")
        return value

    def public(self) -> dict[str, Any]:
        with self.lock:
            return {
                "base_url": self.data["base_url"],
                "model": self.data["model"],
                "has_api_key": bool(self.data["api_key"]),
            }

    def private(self) -> dict[str, str]:
        with self.lock:
            return dict(self.data)

    def update(self, payload: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            updated = dict(self.data)
            if "base_url" in payload:
                if not isinstance(payload["base_url"], str):
                    raise ServiceError("base_url 必须是字符串")
                updated["base_url"] = self._validate_base_url(payload["base_url"])
            if "model" in payload:
                if not isinstance(payload["model"], str):
                    raise ServiceError("model 必须是字符串")
                updated["model"] = self._validate_model(payload["model"])
            if payload.get("clear_api_key") is True:
                updated["api_key"] = ""
            elif isinstance(payload.get("api_key"), str) and payload["api_key"].strip():
                key = payload["api_key"].strip()
                if len(key) > 500 or any(ord(ch) < 32 for ch in key):
                    raise ServiceError("api_key 格式无效")
                updated["api_key"] = key
            self._write(updated)
            self.data = updated
            return self.public()

    def _write(self, value: dict[str, str]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_name(self.path.name + ".tmp")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(value, handle, ensure_ascii=False, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp, self.path)
            os.chmod(self.path, 0o600)
        finally:
            try:
                temp.unlink()
            except FileNotFoundError:
                pass


class Assistant:
    def __init__(self, config: ConfigStore, timeout: float = 45.0, cooldown: float = 15.0) -> None:
        self.config = config
        self.timeout = timeout
        self.histories: dict[str, deque[dict[str, str]]] = {}
        self.last_request: dict[str, float] = {}
        self.lock = threading.RLock()
        self.cooldown = cooldown

    @staticmethod
    def _endpoint(base_url: str) -> str:
        base = base_url.rstrip("/")
        if base.endswith("/chat/completions"):
            return base
        return base + "/chat/completions"

    @staticmethod
    def _clean_answer(value: str) -> str:
        value = re.sub(r"```(?:\w+)?", "", value)
        value = value.replace("**", "").replace("__", "").replace("`", "")
        value = re.sub(r"[\r\n]+", " ", value)
        value = re.sub(r"\s+", " ", value).strip()
        return value[:900]

    @staticmethod
    def _content(response: dict[str, Any]) -> str:
        try:
            content = response["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise ServiceError("LLM 响应缺少 choices[0].message.content", 502) from exc
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "".join(
                str(part.get("text", ""))
                for part in content
                if isinstance(part, dict) and part.get("type") == "text"
            )
        raise ServiceError("LLM 响应内容格式无效", 502)

    def ask(self, payload: dict[str, Any]) -> str:
        player_id = str(payload.get("player_id", "")).strip()
        player_name = str(payload.get("player_name", "玩家")).strip()[:100]
        question = str(payload.get("question", "")).strip()
        state = payload.get("state", {})
        if not player_id or not question:
            raise ServiceError("player_id 和 question 不能为空")
        if len(question) > 500:
            raise ServiceError("问题长度不能超过 500")
        if not isinstance(state, dict):
            raise ServiceError("state 必须是 JSON 对象")

        now = time.monotonic()
        with self.lock:
            elapsed = now - self.last_request.get(player_id, 0.0)
            if elapsed < self.cooldown:
                raise ServiceError("请求过于频繁，请稍后重试", 429)
            self.last_request[player_id] = now
            history = list(self.histories.setdefault(player_id, deque(maxlen=10)))

        config = self.config.private()
        if not config["api_key"]:
            raise ServiceError("AI 服务尚未配置 API key", 503)

        context = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        messages: list[dict[str, str]] = [{"role": "system", "content": SYSTEM_PROMPT}]
        messages.extend(history)
        messages.append({
            "role": "user",
            "content": f"提问玩家：{player_name}\n实时游戏状态：{context}\n问题：{question}",
        })
        body = json.dumps({
            "model": config["model"],
            "messages": messages,
            "temperature": 0.2,
            "stream": False,
        }, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            self._endpoint(config["base_url"]),
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {config['api_key']}",
                "Content-Type": "application/json",
                "User-Agent": "dst-ai-assistant/1.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read(2_000_000)
        except urllib.error.HTTPError as exc:
            LOG.warning("LLM HTTP error: status=%s", exc.code)
            raise ServiceError(f"LLM 请求失败（HTTP {exc.code}）", 502) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            LOG.warning("LLM transport error: %s", type(exc).__name__)
            raise ServiceError("无法连接 LLM 服务", 502) from exc
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ServiceError("LLM 返回了无效 JSON", 502) from exc

        answer = self._clean_answer(self._content(decoded))
        if not answer:
            raise ServiceError("LLM 返回了空回答", 502)
        with self.lock:
            conversation = self.histories.setdefault(player_id, deque(maxlen=10))
            conversation.append({"role": "user", "content": question})
            conversation.append({"role": "assistant", "content": answer})
        return answer


class Application:
    def __init__(self, config_path: Path, timeout: float = 45.0, cooldown: float = 15.0) -> None:
        self.config = ConfigStore(config_path)
        self.assistant = Assistant(self.config, timeout=timeout, cooldown=cooldown)

    def dispatch(self, method: str, path: str, payload: dict[str, Any] | None) -> tuple[int, dict[str, Any]]:
        if method == "GET" and path == "/health":
            public = self.config.public()
            return 200, {"ok": True, "configured": public["has_api_key"]}
        if method == "GET" and path == "/v1/config":
            return 200, self.config.public()
        if method == "POST" and path == "/v1/config":
            return 200, self.config.update(payload or {})
        if method == "POST" and path == "/v1/ask":
            return 200, {"answer": self.assistant.ask(payload or {})}
        raise ServiceError("not found", 404)


class FileBridge:
    """Tails DST logs and delivers responses through the mod's Lua inbox."""

    CHAT_RE = re.compile(
        r"^\[.*?]:\s*\[Say\]\s*\((?P<id>KU_\w+)\)\s*(?P<name>.+?):\s*(?P<message>.+)$"
    )
    STATE_MARKER = "[DST_AI_STATE] "

    def __init__(
        self,
        app: Application,
        chat_log: Path,
        server_log: Path,
        response_file: Path,
        prefix: str = "@ai",
    ) -> None:
        self.app = app
        self.chat_log = chat_log
        self.server_log = server_log
        self.response_file = response_file
        self.prefix = prefix.lower()
        self.state: dict[str, Any] = {}
        self.state_lock = threading.RLock()
        self.response_lock = threading.RLock()
        self.version = int(time.time() * 1000)
        self.executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="dst-ai-request")

    @staticmethod
    def _lua_quote(value: str) -> str:
        output: list[str] = []
        for character in value:
            codepoint = ord(character)
            if character == "\\":
                output.append("\\\\")
            elif character == '"':
                output.append('\\"')
            elif character == "\n":
                output.append("\\n")
            elif character == "\r":
                output.append("\\r")
            elif character == "\t":
                output.append("\\t")
            elif codepoint < 32 or codepoint == 127:
                output.append(f"\\x{codepoint:02x}")
            else:
                output.append(character)
        return "".join(output)

    def _write_response(self, player_name: str, answer: str) -> None:
        with self.response_lock:
            self.version = max(self.version + 1, int(time.time() * 1000))
            content = (
                "return {\n"
                f"    version = {self.version},\n"
                f'    player_name = "{self._lua_quote(player_name)}",\n'
                f'    answer = "{self._lua_quote(answer)}"\n'
                "}\n"
            )
            self.response_file.parent.mkdir(parents=True, exist_ok=True)
            temp = self.response_file.with_name(self.response_file.name + ".tmp")
            temp.write_text(content, encoding="utf-8")
            os.replace(temp, self.response_file)

    def _parse_state(self, line: str) -> None:
        if self.STATE_MARKER not in line:
            return
        raw = line.split(self.STATE_MARKER, 1)[1].strip()
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            return
        state = payload.get("state") if isinstance(payload, dict) else None
        if isinstance(state, dict):
            with self.state_lock:
                self.state = state

    def _load_latest_state(self) -> None:
        try:
            size = self.server_log.stat().st_size
            with self.server_log.open("rb") as handle:
                handle.seek(max(0, size - 4_000_000))
                data = handle.read().decode("utf-8", "replace")
        except OSError:
            return
        for line in data.splitlines():
            self._parse_state(line)

    def _parse_chat(self, line: str) -> None:
        if self.prefix not in line.lower():
            return
        match = self.CHAT_RE.match(line.strip())
        if match is None:
            return
        message = match.group("message").strip()
        if not message.lower().startswith(self.prefix):
            return
        question = message[len(self.prefix):].strip()
        if not question:
            return
        data = {
            "player_id": match.group("id"),
            "player_name": match.group("name").strip(),
            "question": question[:500],
        }
        with self.state_lock:
            data["state"] = dict(self.state)
        self.executor.submit(self._process, data)

    def _process(self, data: dict[str, Any]) -> None:
        try:
            answer = self.app.assistant.ask(data)
        except ServiceError as exc:
            if exc.status == 429:
                answer = "请求过于频繁，请稍后再问。"
            elif exc.status == 503:
                answer = "AI 助手尚未配置，请让管理员输入 API key。"
            else:
                LOG.warning("assistant request failed for %s: %s", data["player_name"], exc)
                answer = "回答问题时出错了，请稍后重试。"
        try:
            self._write_response(str(data["player_name"]), answer)
        except OSError:
            LOG.exception("cannot write mod response file")

    @staticmethod
    def _tail(path: Path, callback: Any) -> None:
        handle = None
        inode = None
        position = 0
        while True:
            try:
                stat = path.stat()
                if handle is None or stat.st_ino != inode or stat.st_size < position:
                    if handle is not None:
                        handle.close()
                    handle = path.open("r", encoding="utf-8", errors="replace")
                    inode = stat.st_ino
                    handle.seek(0, os.SEEK_END)
                    position = handle.tell()
                handle.seek(position)
                for line in handle.readlines():
                    callback(line)
                position = handle.tell()
            except FileNotFoundError:
                pass
            except OSError:
                LOG.exception("error tailing %s", path)
                if handle is not None:
                    handle.close()
                    handle = None
            time.sleep(1)

    def start(self) -> None:
        self._load_latest_state()
        threading.Thread(
            target=self._tail,
            args=(self.server_log, self._parse_state),
            daemon=True,
            name="dst-ai-state-tail",
        ).start()
        threading.Thread(
            target=self._tail,
            args=(self.chat_log, self._parse_chat),
            daemon=True,
            name="dst-ai-chat-tail",
        ).start()
        LOG.info("bridge enabled: chat=%s response=%s", self.chat_log, self.response_file)


def make_handler(app: Application) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "DSTAIService/1.0"

        def log_message(self, fmt: str, *args: object) -> None:
            LOG.info("%s - %s", self.client_address[0], fmt % args)

        def _read_json(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 1_000_000:
                raise ServiceError("request body too large", 413)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                value = json.loads(raw)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ServiceError("invalid JSON") from exc
            if not isinstance(value, dict):
                raise ServiceError("JSON body must be an object")
            return value

        def _handle(self, method: str) -> None:
            try:
                payload = self._read_json() if method == "POST" else None
                status, body = app.dispatch(method, urllib.parse.urlsplit(self.path).path, payload)
            except ServiceError as exc:
                status, body = exc.status, {"error": str(exc)}
            except Exception:
                LOG.exception("unhandled request error")
                status, body = 500, {"error": "internal server error"}
            encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self) -> None:  # noqa: N802
            self._handle("GET")

        def do_POST(self) -> None:  # noqa: N802
            self._handle("POST")

    return Handler


class LocalHTTPServer(ThreadingHTTPServer):
    """HTTP server without a blocking reverse-DNS lookup during startup."""

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = int(port)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="DST AI Assistant companion service")
    parser.add_argument("--host", default=os.environ.get("DST_AI_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("DST_AI_PORT", "8765")))
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(os.environ.get("DST_AI_CONFIG", "/var/lib/dst-ai-assistant/config.json")),
    )
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--cooldown", type=float, default=15.0)
    parser.add_argument("--chat-log", type=Path)
    parser.add_argument("--server-log", type=Path)
    parser.add_argument("--response-file", type=Path)
    parser.add_argument("--prefix", default="@ai")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    app = Application(args.config, timeout=args.timeout, cooldown=args.cooldown)
    bridge_paths = (args.chat_log, args.server_log, args.response_file)
    if any(bridge_paths) and not all(bridge_paths):
        raise SystemExit("--chat-log, --server-log and --response-file must be used together")
    if all(bridge_paths):
        FileBridge(app, args.chat_log, args.server_log, args.response_file, args.prefix).start()
    server = LocalHTTPServer((args.host, args.port), make_handler(app))
    LOG.info("listening on http://%s:%d (config=%s)", args.host, args.port, args.config)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
