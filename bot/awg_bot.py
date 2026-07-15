#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
awg_bot.py — Telegram-бот управления AntiZapret-AWG 2.0.
Полностью кнопочный (единственная команда /start). Старается жить одним
сообщением: каждое нажатие РЕДАКТИРУЕТ текущее сообщение, а не шлёт новое.
Файлы (конфиги/QR/бэкап) — отдельными сообщениями (их редактировать нельзя).
"""

import asyncio
import glob
import html
import os
import re
import socket
import subprocess
import sys
import time

from aiogram import Bot, Dispatcher, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.exceptions import TelegramBadRequest
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
CLIENT_DIR = os.environ.get("AWG_CLIENT_DIR", "/opt/antizapret-awg/clients")
OVPN_DIR = os.environ.get("AWG_OVPN_DIR", "/root/antizapret/client/openvpn")
STATS_PY = os.environ.get("AWG_STATS_PY", "/opt/antizapret-awg/awg_stats.py")
EXPORT_PY = os.environ.get("AWG_EXPORT_PY", "/opt/antizapret-awg/awg-export.py")
VENV_PY = os.environ.get("AWG_VENV_PY", "/opt/antizapret-awg/venv/bin/python")

if not TOKEN or not ADMINS:
    print("AWG_BOT_TOKEN и AWG_BOT_ADMINS обязательны (systemd Environment=)", file=sys.stderr)
    sys.exit(1)

# ванильный AntiZapret кладёт junk-only «-am» конфиги сюда (client.sh опция 4)
VANILLA_AM_DIR = os.environ.get("AWG_VANILLA_AM_DIR", "/root/antizapret/client/amneziawg")
# client.sh не рассчитан на параллельные вызовы (бот + админ-панель) — сериализуем
CLIENT_SH_LOCK = os.environ.get("AWG_CLIENT_SH_LOCK", "/run/antizapret-client.lock")

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


def run_client_sh(args: list, timeout: int = 300) -> tuple:
    """Вызвать ванильный client.sh под flock — client.sh переписывает
    /etc/wireguard/*.conf и chmod 600 на каждом вызове, поэтому параллельный
    запуск (бот + админ-панель) может побить файлы. flock -w ждёт до 30с."""
    if os.path.exists("/usr/bin/flock") or os.path.exists("/bin/flock"):
        return run(["flock", "-w", "30", CLIENT_SH_LOCK, UPSTREAM_SH, *args], timeout)
    return run([UPSTREAM_SH, *args], timeout)


def vanilla_wg_names() -> list:
    """Ванильные WG/AmneziaWG клиенты — источник истины client.sh 6."""
    rc, out, _ = run_client_sh(["6"], timeout=60)
    names = []
    for s in out.splitlines():
        s = s.strip()
        # client.sh 6 печатает имена клиентов; фильтруем служебные строки
        if NAME_RE.match(s) and s not in ("antizapret", "vpn"):
            names.append(s)
    return names


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


def back(cb="menu:main"):
    return [("⬅️ Назад", cb)]


async def show(c: CallbackQuery, text: str, markup: InlineKeyboardMarkup, stamp: bool = False):
    """Редактировать текущее сообщение (жить одним сообщением). Если нельзя
    (текст не изменился / предыдущее — не текстовое после файла) — послать новое."""
    if stamp:
        text = f"{text}\n\n<i>обновлено {time.strftime('%H:%M:%S')}</i>"
    try:
        await c.message.edit_text(text, parse_mode="HTML", reply_markup=markup)
    except TelegramBadRequest:
        try:
            await c.message.answer(text, parse_mode="HTML", reply_markup=markup)
        except Exception:  # noqa: BLE001
            pass


# ── меню ──────────────────────────────────────────────────────────────────────

def menu_header() -> str:
    return (f"🔐 <b>AntiZapret-AWG 2.0</b> · <code>{html.escape(server_host())}</code>\n"
            "Выбери действие:")


def main_menu() -> InlineKeyboardMarkup:
    return kb([
        [("👥 Клиенты", "clients:menu")],
        [("ℹ️ Информация", "info:server")],
        [("🛡 Обфускация", "obf:menu")],
        [("💾 Бэкап", "backup:run"), ("♻️ Восстановить", "restore:ask")],
    ])


def clients_menu() -> InlineKeyboardMarkup:
    return kb([
        [("➕ AmneziaWG 2.0", "awg:menu")],
        [("➕ Ванильный WG", "vanilla:add"), ("➕ OpenVPN", "ovpn:menu")],
        [("⏳ Временный клиент", "temp:menu")],
        [("📋 Список клиентов", "clients:list")],
        back(),
    ])


def client_menu(svc: str, name: str) -> InlineKeyboardMarkup:
    return kb([
        [("ℹ️ Информация", f"clinfo:{svc}:{name}")],
        [("📥 Скачать конфиг", f"cldl:{svc}:{name}")],
        [("🗑 Удалить", f"cldel:{svc}:{name}")],
        [("⬅️ К списку", "clients:list")],
    ])


# ── списки ────────────────────────────────────────────────────────────────────

def awg_names(svc: str) -> list:
    rc, out, _ = run([CLIENT_SH, "list", svc])
    return [s.strip() for s in out.splitlines() if NAME_RE.match(s.strip())]


def ovpn_names() -> list:
    rc, out, _ = run_client_sh(["3"], timeout=60)
    return [s.strip() for s in out.splitlines()
            if NAME_RE.match(s.strip()) and s.strip() != "antizapret-server"]


# ── отправка артефактов (отдельными сообщениями) ─────────────────────────────

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
        await bot.send_message(chat, "🔗 <b>Ссылка vpn:// для приложения Amnezia</b>:",
                               parse_mode="HTML")
        for chunk in (uri[i:i + 3800] for i in range(0, len(uri), 3800)):
            await bot.send_message(chat, f"<code>{html.escape(chunk)}</code>", parse_mode="HTML")


async def send_vanilla_wg_files(chat: int, name: str):
    """Ванильный WG-клиент: отдаём только обфусцированные junk-only «-am» конфиги
    для обоих туннелей (antizapret split + vpn full). Plain-WG файлы не шлём."""
    sent = 0
    for svc, label in (("antizapret", "AntiZapret (split)"), ("vpn", "Полный VPN")):
        conf = os.path.join(VANILLA_AM_DIR, svc, f"{svc}-{name}-am.conf")
        if os.path.exists(conf):
            await bot.send_document(chat, FSInputFile(conf, filename=f"{svc}-{name}-am.conf"),
                                    caption=f"📄 {label} — AmneziaWG (ваниль)")
            sent += 1
    if not sent:
        await bot.send_message(chat, "⚠️ «-am» конфиги ванильного клиента не найдены.")


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


# ── ввод имени клиента ───────────────────────────────────────────────────────

@dp.message(Flow.name, F.text)
async def on_name(m: Message, state: FSMContext):
    if not is_admin(m.chat.id):
        return
    name = m.text.strip()
    if not NAME_RE.match(name):
        return await m.answer("Имя: 1–32 символа (буквы, цифры, _ , -). Ещё раз:")
    data = await state.get_data()
    await state.clear()
    mid = data.get("_mid")
    try:
        await m.delete()                     # убрать введённое имя — меньше сообщений
    except Exception:  # noqa: BLE001
        pass

    async def upd(text, markup=None):        # редактируем исходное сообщение диалога
        if mid:
            try:
                return await bot.edit_message_text(text, m.chat.id, mid,
                                                   parse_mode="HTML", reply_markup=markup)
            except Exception:  # noqa: BLE001
                pass
        await m.answer(text, parse_mode="HTML", reply_markup=markup)

    kind = data.get("kind")
    if kind in ("awg", "temp_awg"):
        svc = data["svc"]; ttl = data.get("ttl")
        await upd(f"⏳ Создаю <b>{html.escape(name)}</b> ({svc})…")
        cmd = [CLIENT_SH, "add", name, svc] + (["--ttl", ttl] if ttl else [])
        rc, out, err = run(cmd)
        if rc != 0:
            return await upd(f"❌ {html.escape(err or out)}", main_menu())
        await send_awg_files(m.chat.id, svc, name)
        await upd(f"✅ <b>{html.escape(name)}</b> ({svc}) готов"
                  + (f" · удалится через {ttl}" if ttl else ""), main_menu())
    elif kind == "vanilla":
        await upd(f"⏳ Создаю ванильного WG <b>{html.escape(name)}</b> (оба туннеля)…")
        # client.sh 4 создаёт клиента сразу в antizapret+vpn (split и full)
        rc, out, err = run_client_sh(["4", name])
        if rc != 0:
            return await upd(f"❌ {html.escape(err or out)[:900]}", main_menu())
        await send_vanilla_wg_files(m.chat.id, name)
        await upd(f"✅ Ванильный WG <b>{html.escape(name)}</b> готов "
                  "(AntiZapret + Полный VPN)", main_menu())
    elif kind in ("ovpn", "temp_ovpn"):
        days = data["days"]
        await upd(f"⏳ Создаю OpenVPN <b>{html.escape(name)}</b> ({days}д)…")
        rc, out, err = run_client_sh(["1", name, days])
        if rc != 0:
            return await upd(f"❌ {html.escape(err or out)[:900]}", main_menu())
        await send_ovpn_files(m.chat.id, name)
        await upd(f"✅ OpenVPN <b>{html.escape(name)}</b> готов", main_menu())


async def ask_name(c: CallbackQuery, state: FSMContext, **data):
    await state.set_state(Flow.name)
    data["_mid"] = c.message.message_id      # чтобы дальше редактировать это же сообщение
    await state.set_data(data)
    await show(c, "✍️ Введи имя клиента (буквы, цифры, _ , -):",
               kb([[("✖️ Отмена", "menu:main")]]))


# ── все callbacks (через show() — редактирование одного сообщения) ───────────

@dp.callback_query()
async def on_cb(c: CallbackQuery, state: FSMContext):
    if not is_admin(c.message.chat.id):
        return await c.answer("⛔️", show_alert=True)
    d = c.data or ""
    await c.answer()

    if d == "menu:main":
        await state.clear()
        return await show(c, menu_header(), main_menu())

    if d == "info:server":
        return await show(c, stats("server"),
                          kb([[("🔄 Обновить", "info:server")], back()]), stamp=True)

    if d == "clients:menu":
        return await show(c, "👥 <b>Клиенты</b>", clients_menu())

    if d == "clients:list":
        az = [("antizapret", n) for n in awg_names("antizapret")]
        vp = [("vpn", n) for n in awg_names("vpn")]
        van = [("vanilla", n) for n in vanilla_wg_names()]
        ov = [("ovpn", n) for n in ovpn_names()]
        rows = []
        for svc, n in (az + vp + van + ov)[:80]:
            tag = {"antizapret": "🌐", "vpn": "🔒", "vanilla": "🅰️", "ovpn": "📄"}[svc]
            rows.append([(f"{tag} {n}", f"cli:{svc}:{n}")])
        if not rows:
            rows = [[("(клиентов нет)", "clients:menu")]]
        rows.append(back("clients:menu"))
        return await show(c, "Выбери клиента:\n🌐/🔒 AWG 2.0 · 🅰️ ваниль WG · 📄 OpenVPN",
                          kb(rows))

    if d.startswith("cli:"):
        _, svc, name = d.split(":", 2)
        tag = {"antizapret": "AmneziaWG 2.0 · AntiZapret", "vpn": "AmneziaWG 2.0 · Полный VPN",
               "vanilla": "Ванильный WG · AntiZapret + Полный VPN",
               "ovpn": "OpenVPN"}.get(svc, svc)
        return await show(c, f"👤 <b>{html.escape(name)}</b>\n{tag}", client_menu(svc, name))

    if d.startswith("clinfo:"):
        _, svc, name = d.split(":", 2)
        if svc == "ovpn":
            return await show(c, f"📄 OpenVPN-клиент <b>{html.escape(name)}</b>\n"
                              "(детальная статистика — для WireGuard/AmneziaWG)",
                              kb([[("⬅️ Назад", f"cli:{svc}:{name}")]]))
        # ванильный клиент фильтруется по origin=vanilla (имя может совпасть с awg2)
        args = ["client", name, "vanilla"] if svc == "vanilla" else ["client", name]
        return await show(c, stats(*args),
                          kb([[("🔄 Обновить", f"clinfo:{svc}:{name}")],
                              [("⬅️ Назад", f"cli:{svc}:{name}")]]), stamp=True)

    if d.startswith("cldl:"):
        _, svc, name = d.split(":", 2)
        await show(c, f"📥 Отправляю конфиг <b>{html.escape(name)}</b>…",
                   kb([[("⬅️ Назад", f"cli:{svc}:{name}")]]))
        if svc == "ovpn":
            await send_ovpn_files(c.message.chat.id, name)
        elif svc == "vanilla":
            await send_vanilla_wg_files(c.message.chat.id, name)
        else:
            conf = os.path.join(CLIENT_DIR, svc, f"{svc}-{name}-am.conf")
            if os.path.exists(conf):
                run([PY, EXPORT_PY, conf, "--name", f"{svc}-{name}",
                     "--outdir", os.path.dirname(conf), "--all"])
            await send_awg_files(c.message.chat.id, svc, name)
        return

    if d.startswith("cldel:"):
        _, svc, name = d.split(":", 2)
        if svc == "ovpn":
            rc, out, err = run_client_sh(["2", name], timeout=120)
        elif svc == "vanilla":
            rc, out, err = run_client_sh(["5", name], timeout=120)  # WG delete
        else:
            rc, out, err = run([CLIENT_SH, "del", name, svc])
        txt = (f"🗑 Удалён: {html.escape(name)}" if rc == 0
               else f"❌ {html.escape(err or out)[:500]}")
        return await show(c, txt, kb([[("⬅️ К списку", "clients:list")], back()]))

    if d == "awg:menu":
        return await show(c, "AmneziaWG — тип:", kb([
            [("🌐 AntiZapret (split)", "awgsvc:antizapret")],
            [("🔒 Полный VPN", "awgsvc:vpn")], back("clients:menu")]))
    if d.startswith("awgsvc:"):
        return await ask_name(c, state, kind="awg", svc=d.split(":", 1)[1])

    if d == "vanilla:add":
        return await ask_name(c, state, kind="vanilla")

    if d == "ovpn:menu":
        return await show(c, "OpenVPN — срок сертификата:", kb([
            [("1 год", "ovpndays:365"), ("3 года", "ovpndays:1095")],
            [("10 лет", "ovpndays:3650")], back("clients:menu")]))
    if d.startswith("ovpndays:"):
        return await ask_name(c, state, kind="ovpn", days=d.split(":", 1)[1])

    if d == "temp:menu":
        return await show(c, "Временный клиент — тип:", kb([
            [("🌐 AWG AntiZapret", "temptype:antizapret")],
            [("🔒 AWG Полный VPN", "temptype:vpn")],
            [("📄 OpenVPN", "temptype:ovpn")], back("clients:menu")]))
    if d.startswith("temptype:"):
        t = d.split(":", 1)[1]
        if t == "ovpn":
            return await show(c, "Срок (OpenVPN — сертификат):", kb([
                [("1 день", "tempod:1"), ("7 дней", "tempod:7")],
                [("30 дней", "tempod:30")], back("clients:menu")]))
        return await show(c, "Время жизни (авто-удаление):", kb([
            [("1 час", f"tempad:{t}:1h"), ("6 часов", f"tempad:{t}:6h")],
            [("1 день", f"tempad:{t}:1d"), ("7 дней", f"tempad:{t}:7d")],
            [("30 дней", f"tempad:{t}:30d")], back("clients:menu")]))
    if d.startswith("tempad:"):
        _, svc, ttl = d.split(":")
        return await ask_name(c, state, kind="temp_awg", svc=svc, ttl=ttl)
    if d.startswith("tempod:"):
        return await ask_name(c, state, kind="temp_ovpn", days=d.split(":", 1)[1])

    if d == "obf:menu":
        return await show(c, "🛡 Обфускация:", kb([
            [("👁 Показать", "obf:show")], [("🔄 Перегенерировать", "obf:regen")], back()]))
    if d == "obf:show":
        rc, out, err = run([OBF_SH, "--show"])
        return await show(c, f"🛡 <code>{html.escape((out or err)[:3500])}</code>",
                          kb([back("obf:menu")]))
    if d == "obf:regen":
        await show(c, "⏳ Перегенерация профиля…", kb([back("obf:menu")]))
        rc, out, err = run([OBF_SH, "--regenerate"], timeout=120)
        if rc == 0:
            run([CLIENT_SH, "regen-all"], timeout=180)
            return await show(c, "✅ Новый профиль применён, конфиги пересозданы.\n"
                              "Клиентам нужно переимпортировать конфиги.", kb([back("obf:menu")]))
        return await show(c, f"❌ {html.escape(err or out)[:800]}", kb([back("obf:menu")]))

    if d == "backup:run":
        await show(c, "💾 Создаю бэкап…", kb([back()]))
        rc, out, err = run([BACKUP_SH, "backup"], timeout=300)
        path = out.splitlines()[-1].strip() if out else ""
        if rc == 0 and os.path.exists(path):
            await bot.send_document(c.message.chat.id, FSInputFile(path, filename=os.path.basename(path)),
                                    caption="✅ Бэкап (OpenVPN + AmneziaWG + конфиги + статистика)")
            return await show(c, "✅ Бэкап отправлен.", kb([back()]))
        return await show(c, f"❌ {html.escape(err or out)[:800]}", kb([back()]))

    if d == "restore:ask":
        _pending_restore.add(c.message.chat.id)
        return await show(c, "♻️ Пришли файл бэкапа (.tar.gz) следующим сообщением.",
                          kb([[("✖️ Отмена", "menu:main")]]))


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
    note = await m.answer("♻️ Восстанавливаю и перезапускаю сервисы…")
    rc, out, err = run([BACKUP_SH, "restore", dst], timeout=300)
    if os.path.exists(dst):
        os.remove(dst)
    await note.edit_text("✅ Восстановлено." if rc == 0 else f"❌ {html.escape(err or out)[:800]}",
                         parse_mode="HTML")
    await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())


async def main():
    from aiogram.types import BotCommand
    await bot.set_my_commands([BotCommand(command="start", description="Меню")])
    print(f"AntiZapret-AWG bot up. Admins: {sorted(ADMINS)}")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
