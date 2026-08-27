# -*- coding: utf-8 -*-
"""Приёмка меню обфускации в боте: предупреждение, фон, честный исход.

Команда для фонового юнита не просто разбирается по строке — она реально
запускается на подставных awg-obfuscation/awg-client, и проверяется файл
результата. Иначе тест доказывал бы только то, что строка собрана.
"""
import asyncio
import os
import shutil
import subprocess
import sys
import tempfile
import types

# tests/ лежит внутри репозитория, поэтому корень берём от самого файла.
# AWG_REPO_ROOT позволяет проверить другую копию дерева, ничего не правя.
ROOT = os.environ.get("AWG_REPO_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import aiogram_stub                                     # noqa: E402
aiogram_stub.install()

REPO = ROOT
# Набор общий для обоих репозиториев, поэтому семейство определяем по
# содержимому дерева, а не по строке в пути.
IS_AZ = os.path.exists(os.path.join(REPO, "patches",
                                    "antizapret-awg-integration.sh"))

os.environ.setdefault("AWG_BOT_TOKEN", "123456:AAstub")
os.environ.setdefault("AWG_BOT_ADMINS", "42")
SVCENV = os.path.join(tempfile.mkdtemp(), "svc.env")
os.environ["AWG_SERVICES_ENV"] = SVCENV
open(SVCENV, "w", encoding="utf-8").write(
    "LAYER2='1'\nLAYER3='1'\nAZ_IFACE=antizapret-awg\nVPN_IFACE=vpn-awg\n"
    "AZ3_IFACE=antizapret-awg3\nVPN3_IFACE=vpn-awg3\nIFACE2=awg2\nIFACE3=awg3\n")

sys.path.insert(0, os.path.join(REPO, "bot"))
import awg_bot as B                                     # noqa: E402

FAIL = []


def chk(name, got, want):
    if got == want:
        print("  ✔ %s" % name)
    else:
        print("  ✘ %s\n     ждали: %r\n     вышло: %r" % (name, want, got))
        FAIL.append(name)


def inc(name, hay, needle):
    if needle in hay:
        print("  ✔ %s" % name)
    else:
        print("  ✘ %s — нет «%s»\n     вышло: %r" % (name, needle, hay[:700]))
        FAIL.append(name)


def noinc(name, hay, needle):
    if needle in hay:
        print("  ✘ %s — лишнее «%s»" % (name, needle))
        FAIL.append(name)
    else:
        print("  ✔ %s" % name)


# ── подставная сцена вокруг обработчика ─────────────────────────────────────
SHOWN, STARTED, KB = [], [], []
RESULT = {"v": ""}
LISTRC = {"v": 0}


class FakeMsg:
    def __init__(self):
        self.chat = types.SimpleNamespace(id=42)

    async def edit_text(self, text, **k):
        SHOWN.append(text)

    async def answer(self, text, **k):
        SHOWN.append(text)


class FakeCB:
    def __init__(self, data):
        self.data = data
        self.message = FakeMsg()
        self.from_user = types.SimpleNamespace(id=42)

    async def answer(self, *a, **k):
        pass


async def fake_show(c, text, markup, stamp=False):
    SHOWN.append(text)
    KB.append([[(b.text, b.callback_data) for b in row]
               for row in getattr(markup, "inline_keyboard", [])])


def fake_start_bg_unit(unit, cmd, logfile):
    STARTED.append((unit, cmd, logfile))
    return 0, "", ""


async def fake_watch_unit(c, unit, logfile, title, done_note, back_cb="upd:menu", **k):
    SHOWN.append(title)


NAMES = {"antizapret": ["ann", "bob", "cat"], "vpn": ["ann", "bob"],
         "antizapret3": ["ann", "dan"], "vpn3": ["dan", "eve", "fox"],
         "awg2": ["ann", "bob", "cat"], "awg3": ["dan", "eve", "fox", "gus"]}


def fake_run(args, **k):
    if len(args) >= 3 and args[1] == "list":
        return LISTRC["v"], "\n".join(NAMES.get(args[2], [])), ""
    return 0, "", ""


B.show = fake_show
B.start_bg_unit = fake_start_bg_unit
B.watch_unit = fake_watch_unit
B.run = fake_run
B.log_tail = lambda f, lines=14, width=3200: "(лог)"
B.obf_result = lambda: RESULT["v"]


def cb(data):
    SHOWN.clear()
    KB.clear()
    asyncio.run(B.on_cb(FakeCB(data), None))
    return SHOWN[-1] if SHOWN else ""


print("== 1. Команда юнита: что в ней =========================================")
cmd = B.obf_apply_cmd(True, "medium", "web")
line = cmd[2]
chk("запускается через bash -c", cmd[:2], ["bash", "-c"])
inc("слой 3.0 получает --v3", line, "--v3")
inc("--regenerate сохраняет host/mtu/fp", line, "--regenerate")
inc("пресет передан", line, "--preset medium")
inc("шаблон передан", line, "--template web")
noinc("fp насильно не задаётся", line, "--fp")
inc("исход пишется в файл", line, "result=")
noinc("шаблон auto не передаётся флагом", B.obf_apply_cmd(False, "high", "auto")[2], "--template")
noinc("перевыпуск сигнатур без --preset", B.obf_apply_cmd(True)[2], "--preset")
inc("но с --regenerate", B.obf_apply_cmd(True)[2], "--regenerate")
if IS_AZ:
    inc("пути конфигов 3.0 заданы явно", line,
        "AWG3_AZ_CONF=/etc/amnezia/amneziawg/antizapret-awg3.conf")
    noinc("чужие пути слоя 2.0 не подмешаны", line, "AWG_AZ_CONF=")

print("\n== 2. Команда юнита: как она РАБОТАЕТ ==================================")


def run_cmd(obf_rc, regen_rc):
    """Запустить настоящую собранную команду на подставных скриптах."""
    d = tempfile.mkdtemp()
    try:
        obf = os.path.join(d, "obf.sh")
        cli = os.path.join(d, "cli.sh")
        mark = os.path.join(d, "regen-was-called")
        open(obf, "w").write("#!/bin/sh\nexit %d\n" % obf_rc)
        open(cli, "w").write("#!/bin/sh\ntouch %s\nexit %d\n" % (mark, regen_rc))
        os.chmod(obf, 0o755)
        os.chmod(cli, 0o755)
        old = (B.OBF_SH, B.CLIENT_SH, B.OBF_RESULT_FILE)
        B.OBF_SH, B.CLIENT_SH = obf, cli
        B.OBF_RESULT_FILE = os.path.join(d, "res")
        try:
            p = subprocess.run(B.obf_apply_cmd(True, "medium", "web"), capture_output=True)
            res = ""
            if os.path.exists(B.OBF_RESULT_FILE):
                for ln in open(B.OBF_RESULT_FILE, encoding="utf-8"):
                    if ln.startswith("result="):
                        res = ln.split("=", 1)[1].strip()
            return res, os.path.exists(mark), p.returncode
        finally:
            B.OBF_SH, B.CLIENT_SH, B.OBF_RESULT_FILE = old
    finally:
        shutil.rmtree(d, ignore_errors=True)


chk("профиль лёг, конфиги пересозданы", run_cmd(0, 0), ("applied", True, 0))
chk("код 3: доехало не всё — но конфиги раздать надо", run_cmd(3, 0), ("unconfirmed", True, 0))
chk("профиль не лёг — regen-all НЕ звался", run_cmd(1, 0), ("apply_failed", False, 1))
chk("regen-all упал — отдельный исход", run_cmd(0, 1), ("regen_failed", True, 1))
print("  (раньше исход читался из хвоста лога, куда regen-all пишет сотни строк)")

print("\n== 3. Счётчик затронутых ===============================================")
LISTRC["v"] = 0
chk("слой 2.0 — люди, а не конфиги", B.layer_client_count(False), 3)
chk("слой 3.0", B.layer_client_count(True), 4)
LISTRC["v"] = 1
chk("список не получен — None, а не успокоительный 0", B.layer_client_count(True), None)
LISTRC["v"] = 0

print("\n== 4. Экран выбора пресета =============================================")
inc("предупреждение про router/low", cb("reconf3:preset"), "router")
inc("сказано, что 3.0 вырождается в 2.0", cb("reconf3:preset"), "работает как 2.0")
noinc("у слоя 2.0 его нет", cb("reconf:preset:2"), "работает как 2.0")

print("\n== 5. Подтверждение перед применением ==================================")
STARTED.clear()
t = cb("reconf3:t:medium:web")
inc("конфиги перестанут работать", t, "перестанут работать")
inc("названо число людей", t, "<b>4</b>")
inc("про второй слой сказано точно", t, "продолжит работать: его профиль не меняется")
chk("НИЧЕГО не запущено до подтверждения", STARTED, [])
inc("кнопка подтверждения", str(KB[-1]), "reconf3:go:medium:web")
inc("слабый пресет назван", cb("reconf3:t:low:auto"), "без header protection")
noinc("для 2.0 такой пометки нет", cb("reconf:t:low:auto"), "без header protection")
LISTRC["v"] = 1
inc("неизвестное число не выдаётся за ноль", cb("reconf3:t:medium:web"), "не удалось определить")
LISTRC["v"] = 0

print("\n== 6. «Новые сигнатуры» тоже спрашивают ================================")
STARTED.clear()
t = cb("obf:regen:3")
inc("экран последствий показан", t, "перестанут работать")
inc("сказано, что пресет прежний", t, "Пресет остаётся прежним")
chk("и ничего не запущено", STARTED, [])
inc("кнопка ведёт на запуск", str(KB[-1]), "obf:regen:go:3")
print("  (раньше эта кнопка отключала всех сразу, без вопроса и синхронно)")

print("\n== 7. Запуск — только в фоне ===========================================")
for res, needle in (("applied", "применён"),
                    ("unconfirmed", "не подтвердил"),
                    ("regen_failed", "без связи"),
                    ("apply_failed", "НЕ трогались"),
                    ("", "исход неизвестен")):
    STARTED.clear()
    RESULT["v"] = res
    t = cb("reconf3:go:medium:web")
    chk("запущен один юнит (%s)" % (res or "пусто"), len(STARTED), 1)
    inc("итог «%s»" % (res or "пусто"), t, needle)

STARTED.clear()
RESULT["v"] = "applied"
cb("obf:regen:go:3")
chk("перевыпуск сигнатур тоже в фоне", len(STARTED), 1)

print("\n== 8. Второй админ не влезает ==========================================")
B.start_bg_unit = lambda u, c_, l: (1, "", "операция уже выполняется")
inc("отказ виден", cb("reconf3:go:medium:web"), "уже выполняется")
B.start_bg_unit = fake_start_bg_unit

print("\n== 9. Пункты в меню обфускации =========================================")
cb("obf:menu")
flat = str(KB[-1])
inc("кнопка смены пресета", flat, "reconf:preset")
inc("перегенерация названа честно", flat, "Новые сигнатуры")

print()
if FAIL:
    print("=== ЕСТЬ ПАДЕНИЯ: %d ===" % len(FAIL))
    sys.exit(1)
print("=== ВСЁ ЗЕЛЁНОЕ ===")
