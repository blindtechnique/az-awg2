#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
az_setup_runner.py — проверка обновлений кода для Telegram-бота.

Полное обновление AntiZapret из бота НЕ выполняется: надёжно проехать
интерактивную анкету setup.sh (промпты `read -e -i`) автоматически не удаётся —
ответы рассинхронизируются и ломают маршрутизацию/DNS. Обновление AntiZapret
делается штатной командой в терминале сервера. Здесь остаётся только проверка,
есть ли смысл обновляться.

Действия:
  check-updates   сравнить код setup.sh AntiZapret и HEAD ветки слоя на GitHub
                  с зафиксированными версиями. JSON в stdout. При первом запуске,
                  если базовой версии ещё нет, — записать текущую как базовую
                  (тогда «изменений нет», а следующий релиз апстрима уже покажется).
"""

import argparse
import hashlib
import json
import subprocess
import sys

AZ_SETUP_URL = ("https://raw.githubusercontent.com/GubernievS/"
                "AntiZapret-VPN/main/setup.sh")
LAYER_REPO = "https://github.com/fageoner/Antizapret-AWG-2.0.git"
AZ_SHA_FILE = "/opt/antizapret-awg/.az-setup-sha"
LAYER_REV_FILE = "/opt/antizapret-awg/.layer-rev"
LOCAL_SETUP = "/root/antizapret/setup.sh"


def sh(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception:  # noqa: BLE001
        return subprocess.CompletedProcess(cmd, 1, "", "")


def _read(path):
    try:
        return open(path, encoding="utf-8").read().strip()
    except OSError:
        return ""


def _write(path, data):
    try:
        open(path, "w", encoding="utf-8").write(data)
    except OSError:
        pass


def _remote_file_sha(url):
    r = sh(["curl", "-fsSL", "--retry", "3", url], timeout=90)
    if r.returncode != 0 or not r.stdout:
        return ""
    return hashlib.sha256(r.stdout.encode()).hexdigest()


def _remote_head(repo, branch="main"):
    r = sh(["git", "ls-remote", repo, f"refs/heads/{branch}"], timeout=60)
    if r.returncode == 0 and r.stdout:
        return r.stdout.split()[0][:12]
    return ""


def check_updates():
    """Есть ли на GitHub изменения КОДА (не списков) — AntiZapret и слоя."""
    res = {"antizapret": {}, "layer": {}}

    # AntiZapret: хэш кода setup.sh. Локальный setup.sh не сохраняется после
    # установки, поэтому базой служит зафиксированный хэш (.az-setup-sha).
    up_sha = _remote_file_sha(AZ_SETUP_URL)
    loc_sha = _read(LOCAL_SETUP)
    if loc_sha:
        loc_sha = hashlib.sha256(loc_sha.encode()).hexdigest()
    else:
        loc_sha = _read(AZ_SHA_FILE)
    known = bool(loc_sha)
    if not known and up_sha:
        # первый запуск — зафиксировать текущую версию как базовую
        _write(AZ_SHA_FILE, up_sha)
        loc_sha = up_sha
    res["antizapret"] = {
        "remote": up_sha[:12], "local": loc_sha[:12],
        "changed": bool(up_sha) and up_sha != loc_sha,
        "known": known,
    }

    # Слой: HEAD ветки форка vs зафиксированная ревизия
    lay_remote = _remote_head(LAYER_REPO)
    lay_local = _read(LAYER_REV_FILE)
    lay_known = bool(lay_local)
    if not lay_known and lay_remote:
        _write(LAYER_REV_FILE, lay_remote)
        lay_local = lay_remote
    res["layer"] = {
        "remote": lay_remote, "local": lay_local,
        "changed": bool(lay_remote) and lay_remote != lay_local,
        "known": lay_known,
    }
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["check-updates"])
    ap.parse_args()
    print(json.dumps(check_updates(), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
