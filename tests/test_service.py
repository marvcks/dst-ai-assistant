from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "service"))

import dst_ai_service as service  # noqa: E402


class FakeResponse:
    def __init__(self, payload: dict) -> None:
        self.payload = json.dumps(payload).encode()

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self, limit: int) -> bytes:
        return self.payload[:limit]


class ConfigStoreTests(unittest.TestCase):
    def test_update_persists_secret_but_public_response_redacts_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            store = service.ConfigStore(path)
            public = store.update({
                "base_url": "https://example.test/v1/",
                "model": "test-model",
                "api_key": "secret-key",
            })
            self.assertEqual(public, {
                "base_url": "https://example.test/v1",
                "model": "test-model",
                "has_api_key": True,
            })
            self.assertNotIn("api_key", public)
            self.assertEqual(json.loads(path.read_text())["api_key"], "secret-key")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_rejects_url_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = service.ConfigStore(Path(directory) / "config.json")
            with self.assertRaises(service.ServiceError):
                store.update({"base_url": "https://user:pass@example.test/v1"})


class AssistantTests(unittest.TestCase):
    def test_openai_compatible_request_and_markdown_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = service.ConfigStore(Path(directory) / "config.json")
            store.update({
                "base_url": "https://example.test/v1",
                "model": "model-x",
                "api_key": "key-x",
            })
            assistant = service.Assistant(store, cooldown=0)
            response = FakeResponse({
                "choices": [{"message": {"content": "**秋天**\n第 3 天"}}],
            })
            with mock.patch("urllib.request.urlopen", return_value=response) as urlopen:
                answer = assistant.ask({
                    "player_id": "KU_test",
                    "player_name": "Player",
                    "question": "现在是什么季节？",
                    "state": {"world": {"season": "autumn", "day": 3}},
                })
            self.assertEqual(answer, "秋天 第 3 天")
            request = urlopen.call_args.args[0]
            self.assertEqual(request.full_url, "https://example.test/v1/chat/completions")
            self.assertEqual(request.get_header("Authorization"), "Bearer key-x")
            sent = json.loads(request.data)
            self.assertEqual(sent["model"], "model-x")
            self.assertIn('"season":"autumn"', sent["messages"][-1]["content"])


class BridgeTests(unittest.TestCase):
    def test_lua_response_escaping_and_chat_parse(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = service.Application(root / "config.json", cooldown=0)
            app.config.update({"api_key": "test"})
            app.assistant.ask = mock.Mock(return_value='回答 "安全"\\完成')
            bridge = service.FileBridge(
                app,
                root / "chat.log",
                root / "server.log",
                root / "response.lua",
            )
            bridge.state = {"world": {"day": 4}}
            bridge._parse_chat("[00:01:02]: [Say] (KU_test) 测试玩家: @ai 第几天？")
            bridge.executor.shutdown(wait=True)
            written = (root / "response.lua").read_text(encoding="utf-8")
            self.assertIn('player_name = "测试玩家"', written)
            self.assertIn('answer = "回答 \\"安全\\"\\\\完成"', written)
            payload = app.assistant.ask.call_args.args[0]
            self.assertEqual(payload["state"]["world"]["day"], 4)


if __name__ == "__main__":
    unittest.main()

