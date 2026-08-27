# -*- coding: utf-8 -*-
"""Приёмка: пояснение про «version 3.1» уходит вместе с конфигом слоя 3.0.

Гоняется настоящая send_awg_files с подставным ботом и настоящими файлами —
проверяем подписи, а не наличие строки в исходнике.
"""
import asyncio
import os
import shutil
import sys
import tempfile

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
V3_SVC = "vpn3" if IS_AZ else "awg3"
V2_SVC = "vpn" if IS_AZ else "awg2"

CLIENTS = tempfile.mkdtemp()
os.environ.setdefault("AWG_BOT_TOKEN", "123456:AAstub")
os.environ.setdefault("AWG_BOT_ADMINS", "42")
os.environ["AWG_CLIENT_DIR"] = CLIENTS
SVCENV = os.path.join(tempfile.mkdtemp(), "svc.env")
os.environ["AWG_SERVICES_ENV"] = SVCENV
open(SVCENV, "w", encoding="utf-8").write("LAYER2='1'\nLAYER3='1'\n")

sys.path.insert(0, os.path.join(REPO, "bot"))
import awg_bot as B                                     # noqa: E402

FAIL = []


def inc(name, hay, needle):
    if needle in hay:
        print("  ✔ %s" % name)
    else:
        print("  ✘ %s — нет «%s»\n     вышло: %r" % (name, needle, hay[:400]))
        FAIL.append(name)


def noinc(name, hay, needle):
    if needle in hay:
        print("  ✘ %s — лишнее «%s»" % (name, needle))
        FAIL.append(name)
    else:
        print("  ✔ %s" % name)


SENT = []


class FakeBot:
    async def send_document(self, chat, f, caption="", **k):
        SENT.append(("doc", caption))

    async def send_photo(self, chat, f, caption="", **k):
        SENT.append(("photo", caption))

    async def send_message(self, chat, text, **k):
        SENT.append(("msg", text))


B.bot = FakeBot()


def hand_out(svc):
    """Выдать клиенту конфиг слоя svc и вернуть весь текст, который он получил."""
    d = os.path.join(CLIENTS, svc)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "%s-ann-am.conf" % svc), "w").write("[Interface]\n")
    SENT.clear()
    asyncio.run(B.send_awg_files(42, svc, "ann"))
    return "\n".join(t for _, t in SENT)


print("== Слой 3.0: пояснение приходит ========================================")
t = hand_out(V3_SVC)
inc("названа версия, которую покажет приложение", t, "version 3.1")
inc("сказано, что так и должно быть", t, "так и должно быть")
inc("названа сборка, с которой это началось", t, "5.0.1.5")
inc("сказано, что параметры отдаются полностью", t, "параметры 3.0 полностью")

print("\n== Слой 2.0: лишнего не приходит =======================================")
t = hand_out(V2_SVC)
noinc("никакой 3.1", t, "3.1")
noinc("и вообще ничего про версию", t, "version")

print("\n== Подписи слоя НЕ переименованы ========================================")
src = open(os.path.join(REPO, "bot", "awg_bot.py"), encoding="utf-8").read()
inc("слой по-прежнему зовётся 3.0", src, "AmneziaWG 3.0")
if IS_AZ:
    noinc("нигде не заявлен слой 3.1", src.replace("version 3.1", ""), "AmneziaWG 3.1")

print("\n== Подпись влезает в лимит Telegram (1024) ==============================")
cap = [c for k, c in SENT if k == "doc"]
t = hand_out(V3_SVC)
cap = [c for k, c in SENT if k == "doc"][0]
if len(cap) <= 1024:
    print("  ✔ длина подписи %d ≤ 1024" % len(cap))
else:
    print("  ✘ подпись %d > 1024 — Telegram отклонит документ" % len(cap))
    FAIL.append("caption")

shutil.rmtree(CLIENTS, ignore_errors=True)
print()
if FAIL:
    print("=== ЕСТЬ ПАДЕНИЯ: %d ===" % len(FAIL))
    sys.exit(1)
print("=== ВСЁ ЗЕЛЁНОЕ ===")
