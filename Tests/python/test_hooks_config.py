import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).parents[2] / "scripts" / "hooks_config.py"
SPEC = importlib.util.spec_from_file_location("hooks_config", SCRIPT)
hooks_config = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(hooks_config)


class HooksConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.hooks_file = self.root / "hooks.json"
        self.helper = self.root / "Application Support" / "kayla-monitor-hook"
        self.initial = {
            "hooks": {
                "UserPromptSubmit": [
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "node /existing/agentmemory/prompt-submit.mjs",
                            }
                        ]
                    }
                ],
                "Stop": [
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "node /existing/agentmemory/stop.mjs",
                            }
                        ]
                    }
                ],
            }
        }
        self.hooks_file.write_text(json.dumps(self.initial), encoding="utf-8")

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_install_is_idempotent_and_preserves_existing_handlers(self):
        config = hooks_config.load_config(self.hooks_file)
        self.assertTrue(hooks_config.install(config, self.helper))
        self.assertFalse(hooks_config.install(config, self.helper))

        self.assertEqual(len(config["hooks"]["UserPromptSubmit"]), 2)
        existing = config["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
        self.assertEqual(existing, "node /existing/agentmemory/prompt-submit.mjs")
        self.assertEqual(
            hooks_config.installed_events(config, self.helper),
            ["UserPromptSubmit", "Stop"],
        )

    def test_uninstall_removes_only_monitor_handlers(self):
        config = hooks_config.load_config(self.hooks_file)
        hooks_config.install(config, self.helper)
        self.assertTrue(hooks_config.uninstall(config, self.helper))
        self.assertEqual(hooks_config.installed_events(config, self.helper), [])
        self.assertEqual(
            config["hooks"]["Stop"][0]["hooks"][0]["command"],
            "node /existing/agentmemory/stop.mjs",
        )

    def test_backup_and_atomic_write_leave_valid_json(self):
        backup_directory = self.root / "backups"
        backup_path = hooks_config.backup(self.hooks_file, backup_directory)
        self.assertIsNotNone(backup_path)
        self.assertEqual(json.loads(backup_path.read_text()), self.initial)

        config = hooks_config.load_config(self.hooks_file)
        hooks_config.install(config, self.helper)
        hooks_config.atomic_write(self.hooks_file, config)
        reloaded = hooks_config.load_config(self.hooks_file)
        self.assertEqual(
            hooks_config.installed_events(reloaded, self.helper),
            ["UserPromptSubmit", "Stop"],
        )


if __name__ == "__main__":
    unittest.main()
