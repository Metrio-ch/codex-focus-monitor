#!/usr/bin/env python3
"""Surgically add or remove Kayla Monitor handlers in Codex hooks.json."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import tempfile
from datetime import datetime, timezone


EVENTS = ("UserPromptSubmit", "Stop")
MARKER = "--event-bridge kayla-monitor-v1"


def load_config(path: Path) -> dict:
    if not path.exists():
        return {"hooks": {}}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("hooks.json 顶层必须是对象")
    if "hooks" not in data:
        data["hooks"] = {}
    if not isinstance(data["hooks"], dict):
        raise ValueError("hooks.json 的 hooks 字段必须是对象")
    return data


def command_for(helper: Path) -> str:
    return f"{shlex.quote(str(helper))} {MARKER}"


def is_monitor_handler(handler: object, helper: Path | None = None) -> bool:
    if not isinstance(handler, dict):
        return False
    command = handler.get("command")
    if not isinstance(command, str):
        return False
    if MARKER in command:
        return True
    return helper is not None and str(helper) in command and helper.name == "kayla-monitor-hook"


def install(config: dict, helper: Path) -> bool:
    changed = False
    hooks = config["hooks"]
    desired_command = command_for(helper)

    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise ValueError(f"hooks.{event} 必须是数组")

        already_present = any(
            isinstance(group, dict)
            and isinstance(group.get("hooks"), list)
            and any(is_monitor_handler(handler, helper) for handler in group["hooks"])
            for group in groups
        )
        if already_present:
            continue

        groups.append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": desired_command,
                        "async": True,
                        "timeout": 2,
                    }
                ]
            }
        )
        changed = True
    return changed


def uninstall(config: dict, helper: Path | None) -> bool:
    changed = False
    hooks = config["hooks"]

    for event in EVENTS:
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            original_handlers = group["hooks"]
            kept_handlers = [handler for handler in original_handlers if not is_monitor_handler(handler, helper)]
            if len(kept_handlers) != len(original_handlers):
                changed = True
            if kept_handlers:
                updated_group = dict(group)
                updated_group["hooks"] = kept_handlers
                kept_groups.append(updated_group)
        hooks[event] = kept_groups
    return changed


def installed_events(config: dict, helper: Path | None) -> list[str]:
    installed = []
    hooks = config.get("hooks", {})
    for event in EVENTS:
        groups = hooks.get(event, [])
        if any(
            isinstance(group, dict)
            and isinstance(group.get("hooks"), list)
            and any(is_monitor_handler(handler, helper) for handler in group["hooks"])
            for group in groups
        ):
            installed.append(event)
    return installed


def backup(path: Path, backup_directory: Path) -> Path | None:
    if not path.exists():
        return None
    backup_directory.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    destination = backup_directory / f"hooks-{stamp}.json"
    shutil.copy2(path, destination)
    return destination


def atomic_write(path: Path, config: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    existing_mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    data = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(prefix="hooks.", suffix=".json", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, existing_mode)
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "uninstall", "check"))
    parser.add_argument("--hooks", type=Path, required=True)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--backup-dir", type=Path)
    args = parser.parse_args()

    if args.action == "install" and args.helper is None:
        parser.error("install 需要 --helper")

    config = load_config(args.hooks)
    if args.action == "check":
        events = installed_events(config, args.helper)
        print(json.dumps({"status": "checked", "installedEvents": events}, ensure_ascii=False))
        return 0

    changed = install(config, args.helper) if args.action == "install" else uninstall(config, args.helper)
    backup_path = None
    if changed:
        backup_directory = args.backup_dir or args.hooks.parent / "kayla-monitor-backups"
        backup_path = backup(args.hooks, backup_directory)
        atomic_write(args.hooks, config)

    print(
        json.dumps(
            {
                "status": "installed" if args.action == "install" else "uninstalled",
                "changed": changed,
                "installedEvents": installed_events(config, args.helper),
                "backup": str(backup_path) if backup_path else None,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

