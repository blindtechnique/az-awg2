# -*- coding: utf-8 -*-
"""Приёмка: check-updates сравнивает слой с ТОЙ веткой, откуда его ставили.

Модуль загружается настоящий, подменяются только пути к файлам и git ls-remote.
"""
import importlib.util
import os
import shutil
import sys
import tempfile

# tests/ лежит внутри репозитория, поэтому корень берём от самого файла.
# AWG_REPO_ROOT позволяет проверить другую копию дерева, ничего не правя.
ROOT = os.environ.get("AWG_REPO_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))

SRC = os.path.join(ROOT, "overlay", "bin", "az_setup_runner.py")

spec = importlib.util.spec_from_file_location("runner", SRC)
R = importlib.util.module_from_spec(spec)
spec.loader.exec_module(R)

FAIL = []


def chk(name, got, want):
    if got == want:
        print("  ✔ %s" % name)
    else:
        print("  ✘ %s\n     ждали: %r\n     вышло: %r" % (name, want, got))
        FAIL.append(name)


# ── подставные ветки на «GitHub»: у каждой своя голова ──────────────────────
HEADS = {"main": "aaaaaaaaaaaa", "beta": "bbbbbbbbbbbb"}
ASKED = []


def fake_remote_head(repo, branch="main"):
    ASKED.append(branch)
    return HEADS.get(branch, "")


R._remote_head = fake_remote_head
R._remote_file_sha = lambda url: "0" * 64
R.LOCAL_SETUP = "/nonexistent"


def run(layer_branch, bot_env_line, layer_rev):
    """→ (у какой ветки спросили, changed, known)"""
    d = tempfile.mkdtemp()
    try:
        R.LAYER_BRANCH_FILE = os.path.join(d, ".layer-branch")
        R.BOT_ENV = os.path.join(d, "bot.env")
        R.LAYER_REV_FILE = os.path.join(d, ".layer-rev")
        R.AZ_SHA_FILE = os.path.join(d, ".az-setup-sha")
        if layer_branch:
            open(R.LAYER_BRANCH_FILE, "w").write(layer_branch + "\n")
        if bot_env_line:
            open(R.BOT_ENV, "w").write("AWG_BOT_TOKEN=1:x\n" + bot_env_line + "\n")
        if layer_rev:
            open(R.LAYER_REV_FILE, "w").write(layer_rev + "\n")
        ASKED.clear()
        lay = R.check_updates()["layer"]
        healed = (open(R.LAYER_BRANCH_FILE).read().strip()
                  if os.path.exists(R.LAYER_BRANCH_FILE) else "-")
        return ASKED[-1], lay["changed"], lay["known"], healed
    finally:
        shutil.rmtree(d, ignore_errors=True)


BETA_URL = ("AWG_INSTALL_SH_URL=https://raw.githubusercontent.com/"
            "blindtechnique/az-awg2/beta/install.sh")
MAIN_URL = BETA_URL.replace("/beta/", "/main/")

print("== Установка с beta: сравнивать надо с beta ============================")
chk("спросили beta, расхождения нет", run("beta", MAIN_URL, HEADS["beta"]),
    ("beta", False, True, "beta"))
print("  (раньше спрашивали main и получали «есть изменения» навсегда)")
chk("beta отстала — изменение настоящее", run("beta", "", "0" * 12),
    ("beta", True, True, "beta"))

print("\n== Установка с main ====================================================")
chk("спросили main", run("main", BETA_URL, HEADS["main"]),
    ("main", False, True, "main"))

print("\n== Файла .layer-branch нет: чиним из URL бота ==========================")
chk("ветка восстановлена из bot.env и записана",
    run("", BETA_URL, HEADS["beta"]), ("beta", False, True, "beta"))
chk("main-установка остаётся на main",
    run("", MAIN_URL, HEADS["main"]), ("main", False, True, "main"))

print("\n== Восстанавливать нечего: прежнее поведение ===========================")
chk("нет ни файла, ни URL — main", run("", "", HEADS["main"]),
    ("main", False, True, "-"))
chk("мусор вместо URL", run("", "AWG_INSTALL_SH_URL=", HEADS["main"]),
    ("main", False, True, "-"))

print("\n== Первый запуск без .layer-rev ========================================")
chk("не с чем сравнить — known=False", run("beta", "", ""),
    ("beta", False, False, "beta"))

print()
if FAIL:
    print("=== ЕСТЬ ПАДЕНИЯ: %d ===" % len(FAIL))
    sys.exit(1)
print("=== ВСЁ ЗЕЛЁНОЕ ===")
