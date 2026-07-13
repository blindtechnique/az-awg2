#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
awg_bot.py — Telegram-бот управления AntiZapret-AWG 2.0. Полностью кнопочный
(единственная команда /start).

Структура меню:
  /start → главное меню:
     👥 Клиенты   → ➕AmneziaWG · ➕OpenVPN · ⏳Временный · 📋Список
                    Список → клиент кнопкой → ℹ️Информация · 📥Скачать · 🗑Удалить
     ℹ️ Информация → серверная панель (CPU/RAM/диск/сеть, онлайн, топ-5, трафик)
     🛡 Обфускация · 💾 Бэкап · ♻️ Восстановить

Доступ по whitelist chat_id. Конфиг через systemd Environment=.
"""

import asyncio
import glob
import html
import os
import re
import socket
import subprocess
import sys

from aiogram import Bot, Dispatcher, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import (
    Message, FSInputFile, CallbackQuery,
    InlineKeyboardMarkup, InlineKeyboardButton,
)

TOKEN = os.environ.get("AWG_BOT_TOKEN", "")
ADMINS = {int(x) for x in os.environ.get("AWG_BOT_ADMINS", "").replace(" ", "").split(",") if x}
CLIENT_SH = os.environ.get("AWG_CLIENT_SH", "/usr/local/bin/awg-client")
OBF_SH = os.environ.get("AWG_OBF_SH", "/usr/local/bin/awg-obfuscation")
BACKUP_SH = os.environ.get("AWG_BACKUP_SH", "/usr/local/bin/awg-backup")
UPSTREAM_SH = os.environ.get("AWG_UPSTREAM_CLIENT_SH", "/root/antizapret/client.sh")
CLIENT_DIR = os.environ.get("AWG_CLIENT_DIR", "/root/antizapret/client/amneziawg")
OVPN_DIR = os.environ.get("AWG_OVPN_DIR", "/root/antizapret/client/openvpn")
STATS_PY = os.environ.get("AWG_STATS_PY", "/root/antizapret/awg/awg_stats.py")
EXPORT_PY = os.environ.get("AWG_EXPORT_PY", "/root/antizapret/awg/awg-export.py")
VENV_PY = os.environ.get("AWG_VENV_PY", "/root/antizapret/awg/venv/bin/python")

if not TOKEN or not ADMINS:
    print("AWG_BOT_TOKEN и AWG_BOT_ADMINS обязательны (systemd Environment=)", file=sys.stderr)
    sys.exit(1)

NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
PY = VENV_PY if os.path.exists(VENV_PY) else "python3"
bot = Bot(TOKEN)
dp = Dispatcher(storage=MemoryStorage())
_pending_restore = set()


class Flow(StatesGroup):
    name = State()


def is_admin(cid: int) -> bool:
    return cid in ADMINS


def run(cmd: list, timeout: int = 180) -> tuple:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def stats(*a) -> str:
    rc, out, err = run([PY, STATS_PY, *a])
    return out or err or "нет данных"


def server_host() -> str:
    try:
        for line in open("/root/antizapret/setup", encoding="utf-8"):
            if line.startswith("WIREGUARD_HOST="):
                h = line.split("=", 1)[1].strip().strip('"')
                if h:
                    return h
    except OSError:
        pass
    try:
        return socket.gethostname()
    except Exception:  # noqa: BLE001
        return "server"


def kb(rows) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=t, callback_data=d) for t, d in row] for row in rows])


async def edit_or_send(c: CallbackQuery, text: str, markup: InlineKeyboardMarkup):
    """Обновить текущее сообщение (а не слать новое). Метка времени гарантирует
    отличие текста, чтобы Telegram не ругался 'message is not modified'."""
    import time as _t
    from aiogram.exceptions import TelegramBadRequest
    stamped = text + f"\n\n<i>обновлено {_t.strftime('%H:%M:%S')}</i>"
    try:
        await c.message.edit_text(stamped, parse_mode="HTML", reply_markup=markup)
    except TelegramBadRequest:
        await c.message.answer(stamped, parse_mode="HTML", reply_markup=markup)


def back(cb="menu:main"):
    return [("⬅️ Назад", cb)]


def main_menu() -> InlineKeyboardMarkup:
    return kb([
        [("👥 Клиенты", "clients:menu")],
        [("ℹ️ Информация", "info:server")],
        [("🛡 Обфускация", "obf:menu")],
        [("💾 Бэкап", "backup:run"), ("♻️ Восстановить", "restore:ask")],
    ])


def clients_menu() -> InlineKeyboardMarkup:
    return kb([
        [("➕ AmneziaWG", "awg:menu"), ("➕ OpenVPN", "ovpn:menu")],
        [("⏳ Временный клиент", "temp:menu")],
        [("📋 Список клиентов", "clients:list")],
        back(),
    ])


def menu_header() -> str:
    return (f"🔐 <b>AntiZapret-AWG 2.0</b> · <code>{html.escape(server_host())}</code>\n"
            "Выбери действие:")


# ── списки клиентов ──────────────────────────────────────────────────────────

def awg_names(svc: str) -> list:
    rc, out, _ = run([CLIENT_SH, "list", svc])
    return [s.strip() for s in out.splitlines() if NAME_RE.match(s.strip())]


def ovpn_names() -> list:
    rc, out, _ = run([UPSTREAM_SH, "3"], timeout=60)
    return [s.strip() for s in out.splitlines()
            if NAME_RE.match(s.strip()) and s.strip() != "antizapret-server"]


# ── отправка артефактов ──────────────────────────────────────────────────────

async def send_awg_files(chat: int, svc: str, name: str):
    base = os.path.join(CLIENT_DIR, svc, f"{svc}-{name}")
    conf, qr, vpn = base + "-am.conf", base + ".png", base + ".vpn"
    if os.path.exists(conf):
        await bot.send_document(chat, FSInputFile(conf, filename=f"{name}.conf"),
                                caption=f"📄 {svc}/{name} — AmneziaWG")
    if os.path.exists(qr):
        await bot.send_photo(chat, FSInputFile(qr),
                             caption="📱 QR — отсканируй в приложении AmneziaWG")
    if os.path.exists(vpn):
        uri = open(vpn, encoding="utf-8").read().strip()
        await bot.send_message(chat, "🔗 <b>Ссылка vpn:// для приложения Amnezia</b> "
                               "(скопируй, вставь «из буфера»):", parse_mode="HTML")
        for c in (uri[i:i + 3800] for i in range(0, len(uri), 3800)):
            await bot.send_message(chat, f"<code>{html.escape(c)}</code>", parse_mode="HTML")


async def send_ovpn_files(chat: int, name: str):
    sent = 0
    for sub, label in (("antizapret", "split-routing"), ("vpn", "полный туннель")):
        found = sorted(glob.glob(os.path.join(OVPN_DIR, sub, f"{sub}-{name}-*.ovpn"))
                       + glob.glob(os.path.join(OVPN_DIR, sub, f"{sub}-{name}.ovpn")))
        if found:
            await bot.send_document(chat, FSInputFile(found[0], filename=os.path.basename(found[0])),
                                    caption=f"📄 OpenVPN {label}")
            sent += 1
    if not sent:
        await bot.send_message(chat, "⚠️ .ovpn не найдены.")


# ── /start ───────────────────────────────────────────────────────────────────

@dp.message(Command("start"))
async def cmd_start(m: Message, state: FSMContext):
    if not is_admin(m.chat.id):
        return await m.answer("⛔️ Доступ запрещён.")
    await state.clear()
    await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())


async def show_menu(target):
    await target.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())


# ── ввод имени клиента (единственный текстовый шаг) ──────────────────────────

@dp.message(Flow.name, F.text)
async def on_name(m: Message, state: FSMContext):
    if not is_admin(m.chat.id):
        return
    name = m.text.strip()
    if not NAME_RE.match(name):
        return await m.answer("Имя: 1–32 символа (буквы, цифры, _ , -). Ещё раз:")
    data = await state.get_data()
    await state.clear()
    kind = data.get("kind")
    if kind in ("awg", "temp_awg"):
        svc = data["svc"]; ttl = data.get("ttl")
        await m.answer(f"⏳ Создаю {html.escape(name)} ({svc}{', '+ttl if ttl else ''})…")
        cmd = [CLIENT_SH, "add", name, svc] + (["--ttl", ttl] if ttl else [])
        rc, out, err = run(cmd)
        if rc != 0:
            await m.answer(f"❌ {html.escape(err or out)}", parse_mode="HTML")
        else:
            await send_awg_files(m.chat.id, svc, name)
            if ttl:
                await m.answer(f"⏳ Удалится через {ttl}.")
    elif kind in ("ovpn", "temp_ovpn"):
        days = data["days"]
        await m.answer(f"⏳ Создаю OpenVPN {html.escape(name)} ({days}д)…")
        rc, out, err = run([UPSTREAM_SH, "1", name, days], timeout=300)
        if rc != 0:
            await m.answer(f"❌ {html.escape(err or out)[:900]}", parse_mode="HTML")
        else:
            await send_ovpn_files(m.chat.id, name)
    await show_menu(m)


async def ask_name(c: CallbackQuery, state: FSMContext, **data):
    await state.set_state(Flow.name)
    await state.set_data(data)
    await c.message.answer("✍️ Введи имя клиента (буквы, цифры, _ , -):",
                           reply_markup=kb([[("✖️ Отмена", "menu:main")]]))


# ── per-client submenu ───────────────────────────────────────────────────────

def client_menu(svc: str, name: str) -> InlineKeyboardMarkup:
    return kb([
        [("ℹ️ Информация", f"clinfo:{svc}:{name}")],
        [("📥 Скачать конфиг", f"cldl:{svc}:{name}")],
        [("🗑 Удалить", f"cldel:{svc}:{name}")],
        [("⬅️ К списку", "clients:list")],
    ])


# ── все callbacks ─────────────────────────────────────────────────────────────

@dp.callback_query()
async def on_cb(c: CallbackQuery, state: FSMContext):
    if not is_admin(c.message.chat.id):
        return await c.answer("⛔️", show_alert=True)
    d = c.data or ""

    if d == "menu:main":
        await state.clear(); await show_menu(c.message); return await c.answer()

    # ── информация о сервере ──
    if d == "info:server":
        await edit_or_send(c, stats("server"),
                           kb([[("🔄 Обновить", "info:server")], back()]))

    # ── меню клиентов ──
    elif d == "clients:menu":
        await c.message.answer("👥 <b>Клиенты</b>", parse_mode="HTML", reply_markup=clients_menu())
    elif d == "clients:list":
        az = [("antizapret", n) for n in awg_names("antizapret")]
        vp = [("vpn", n) for n in awg_names("vpn")]
        ov = [("ovpn", n) for n in ovpn_names()]
        rows = []
        for svc, n in (az + vp + ov)[:80]:
            tag = {"antizapret": "🌐", "vpn": "🔒", "ovpn": "📄"}[svc]
            rows.append([(f"{tag} {n}", f"cli:{svc}:{n}")])
        if not rows:
            rows = [[("(клиентов нет)", "clients:menu")]]
        rows.append(back("clients:menu"))
        await c.message.answer("Выбери клиента:", reply_markup=kb(rows))
    elif d.startswith("cli:"):
        _, svc, name = d.split(":", 2)
        tag = {"antizapret": "AmneziaWG · AntiZapret", "vpn": "AmneziaWG · Полный VPN",
               "ovpn": "OpenVPN"}.get(svc, svc)
        await c.message.answer(f"👤 <b>{html.escape(name)}</b>\n{tag}",
                               parse_mode="HTML", reply_markup=client_menu(svc, name))
    elif d.startswith("clinfo:"):
        _, svc, name = d.split(":", 2)
        if svc == "ovpn":
            await c.message.answer(f"📄 OpenVPN-клиент <b>{html.escape(name)}</b>\n"
                                   "(детальная статистика доступна для AmneziaWG)",
                                   parse_mode="HTML", reply_markup=kb([[("⬅️ Назад", f"cli:{svc}:{name}")]]))
        else:
            await edit_or_send(c, stats("client", name),
                               kb([[("🔄 Обновить", f"clinfo:{svc}:{name}")],
                                   [("⬅️ Назад", f"cli:{svc}:{name}")]]))
    elif d.startswith("cldl:"):
        _, svc, name = d.split(":", 2)
        if svc == "ovpn":
            await send_ovpn_files(c.message.chat.id, name)
        else:
            conf = os.path.join(CLIENT_DIR, svc, f"{svc}-{name}-am.conf")
            if os.path.exists(conf):
                run([PY, EXPORT_PY, conf, "--name", f"{svc}-{name}",
                     "--outdir", os.path.dirname(conf), "--all"])
            await send_awg_files(c.message.chat.id, svc, name)
        await c.message.answer("Готово.", reply_markup=kb([[("⬅️ Назад", f"cli:{svc}:{name}")]]))
    elif d.startswith("cldel:"):
        _, svc, name = d.split(":", 2)
        if svc == "ovpn":
            rc, out, err = run([UPSTREAM_SH, "2", name], timeout=120)
        else:
            rc, out, err = run([CLIENT_SH, "del", name, svc])
        await c.message.answer(f"🗑 Удалён: {html.escape(name)}" if rc == 0
                               else f"❌ {html.escape(err or out)[:500]}", parse_mode="HTML",
                               reply_markup=kb([[("⬅️ К списку", "clients:list")]]))

    # ── создание AmneziaWG ──
    elif d == "awg:menu":
        await c.message.answer("AmneziaWG — тип:", reply_markup=kb([
            [("🌐 AntiZapret (split)", "awgsvc:antizapret")],
            [("🔒 Полный VPN", "awgsvc:vpn")], back("clients:menu")]))
    elif d.startswith("awgsvc:"):
        await ask_name(c, state, kind="awg", svc=d.split(":", 1)[1])

    # ── создание OpenVPN ──
    elif d == "ovpn:menu":
        await c.message.answer("OpenVPN — срок сертификата:", reply_markup=kb([
            [("1 год", "ovpndays:365"), ("3 года", "ovpndays:1095")],
            [("10 лет", "ovpndays:3650")], back("clients:menu")]))
    elif d.startswith("ovpndays:"):
        await ask_name(c, state, kind="ovpn", days=d.split(":", 1)[1])

    # ── временный ──
    elif d == "temp:menu":
        await c.message.answer("Временный клиент — тип:", reply_markup=kb([
            [("🌐 AWG AntiZapret", "temptype:antizapret")],
            [("🔒 AWG Полный VPN", "temptype:vpn")],
            [("📄 OpenVPN", "temptype:ovpn")], back("clients:menu")]))
    elif d.startswith("temptype:"):
        t = d.split(":", 1)[1]
        if t == "ovpn":
            await c.message.answer("Срок (OpenVPN — сертификат):", reply_markup=kb([
                [("1 день", "tempod:1"), ("7 дней", "tempod:7")],
                [("30 дней", "tempod:30")], back("clients:menu")]))
        else:
            await c.message.answer("Время жизни (авто-удаление):", reply_markup=kb([
                [("1 час", f"tempad:{t}:1h"), ("6 часов", f"tempad:{t}:6h")],
                [("1 день", f"tempad:{t}:1d"), ("7 дней", f"tempad:{t}:7d")],
                [("30 дней", f"tempad:{t}:30d")], back("clients:menu")]))
    elif d.startswith("tempad:"):
        _, svc, ttl = d.split(":")
        await ask_name(c, state, kind="temp_awg", svc=svc, ttl=ttl)
    elif d.startswith("tempod:"):
        await ask_name(c, state, kind="temp_ovpn", days=d.split(":", 1)[1])

    # ── обфускация ──
    elif d == "obf:menu":
        await c.message.answer("Обфускация:", reply_markup=kb([
            [("👁 Показать", "obf:show")], [("🔄 Перегенерировать", "obf:regen")], back()]))
    elif d == "obf:show":
        rc, out, err = run([OBF_SH, "--show"])
        await c.message.answer(f"🛡 <code>{html.escape((out or err)[:3500])}</code>",
                               parse_mode="HTML", reply_markup=kb([back()]))
    elif d == "obf:regen":
        await c.message.answer("⏳ Перегенерация…")
        rc, out, err = run([OBF_SH, "--regenerate"], timeout=120)
        if rc == 0:
            run([CLIENT_SH, "regen-all"], timeout=180)
            await c.message.answer("✅ Новый профиль применён, конфиги пересозданы. "
                                   "Клиентам нужно переимпортировать конфиги.")
        else:
            await c.message.answer(f"❌ {html.escape(err or out)}", parse_mode="HTML")
        await show_menu(c.message)

    # ── бэкап/восстановление ──
    elif d == "backup:run":
        await c.message.answer("💾 Создаю бэкап…")
        rc, out, err = run([BACKUP_SH, "backup"], timeout=300)
        path = out.splitlines()[-1].strip() if out else ""
        if rc == 0 and os.path.exists(path):
            await bot.send_document(c.message.chat.id, FSInputFile(path, filename=os.path.basename(path)),
                                    caption="✅ Бэкап (OpenVPN + AmneziaWG + конфиги + статистика)")
        else:
            await c.message.answer(f"❌ {html.escape(err or out)[:800]}", parse_mode="HTML")
        await show_menu(c.message)
    elif d == "restore:ask":
        _pending_restore.add(c.message.chat.id)
        await c.message.answer("♻️ Пришли файл бэкапа (.tar.gz) следующим сообщением.",
                               reply_markup=kb([[("✖️ Отмена", "menu:main")]]))

    await c.answer()


# ── приём файла бэкапа ───────────────────────────────────────────────────────

@dp.message(F.document)
async def on_document(m: Message):
    if not is_admin(m.chat.id) or m.chat.id not in _pending_restore:
        return
    fn = (m.document.file_name or "").lower()
    if not fn.endswith((".tar.gz", ".tgz")):
        return await m.answer("Нужен .tar.gz от «Бэкап».")
    _pending_restore.discard(m.chat.id)
    dst = f"/tmp/awg-restore-{m.chat.id}.tar.gz"
    f = await bot.get_file(m.document.file_id)
    await bot.download_file(f.file_path, dst)
    await m.answer("♻️ Восстанавливаю и перезапускаю сервисы…")
    rc, out, err = run([BACKUP_SH, "restore", dst], timeout=300)
    if os.path.exists(dst):
        os.remove(dst)
    await m.answer("✅ Восстановлено." if rc == 0 else f"❌ {html.escape(err or out)[:800]}",
                   parse_mode="HTML", reply_markup=main_menu())


async def main():
    from aiogram.types import BotCommand
    await bot.set_my_commands([BotCommand(command="start", description="Меню")])
    print(f"AntiZapret-AWG bot up. Admins: {sorted(ADMINS)}")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
