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
import json
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
RUNNER_PY = os.environ.get("AWG_RUNNER_PY", "/opt/antizapret-awg/az_setup_runner.py")
DOALL_SH = os.environ.get("AWG_DOALL_SH", "/root/antizapret/doall.sh")
SERVICES_ENV = os.environ.get("AWG_SERVICES_ENV", "/etc/amnezia/amneziawg/services.env")
STATUS_FILE = os.environ.get("AWG_UPDATE_STATUS", "/opt/antizapret-awg/az-update-status.json")
ANSWERS_FILE = os.environ.get("AWG_ANSWERS_FILE", "/opt/antizapret-awg/setup-answers.env")
INSTALL_SH_URL = os.environ.get(
    "AWG_INSTALL_SH_URL",
    "https://raw.githubusercontent.com/fageoner/Antizapret-AWG-2.0/main/install.sh")
LOG_DIR = "/var/log"

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


def run(cmd: list, timeout: int = 180, env: dict = None) -> tuple:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL, env=env)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def vanilla_file_base(name: str) -> str:
    """Реплика логики FILE_NAME из ванильного client.sh (строки 49-51):
    из ИМЕНИ клиента срезаются префиксы antizapret-/vpn- (последовательно),
    а к имени ФАЙЛА ваниль приклеивает '-(SERVER_HOST)'. Поэтому клиент
    'antizapret-client' лежит в файле 'antizapret-client-(домен)-am.conf'."""
    if name.startswith("antizapret-"):
        name = name[len("antizapret-"):]
    if name.startswith("vpn-"):
        name = name[len("vpn-"):]
    return name


def find_vanilla_file(directory: str, svc: str, name: str, suffix: str):
    """Найти файл стокового клиента: сперва точное имя с '-(хост)', затем без
    суффикса (старые версии ванили). Возвращает путь или None."""
    base = vanilla_file_base(name)
    for pat in (f"{svc}-{base}-(*){suffix}", f"{svc}-{base}{suffix}"):
        found = sorted(glob.glob(os.path.join(directory, svc, pat)))
        if found:
            return found[0]
    return None


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


# ── фоновые долгие операции (systemd-run: переживают рестарт бота) ──────────

def obf_env() -> dict:
    """awg-obfuscation.sh по умолчанию смотрит на antizapret.conf/vpn.conf,
    а в parallel-режиме серверные конфиги зовутся antizapret-awg/vpn-awg —
    передаём точные пути из services.env."""
    env = dict(os.environ)
    az, vpn = "antizapret", "vpn"
    try:
        for line in open(SERVICES_ENV, encoding="utf-8"):
            line = line.strip()
            if line.startswith("AZ_IFACE="):
                az = line.split("=", 1)[1]
            elif line.startswith("VPN_IFACE="):
                vpn = line.split("=", 1)[1]
    except OSError:
        pass
    env["AWG_AZ_CONF"] = f"/etc/amnezia/amneziawg/{az}.conf"
    env["AWG_VPN_CONF"] = f"/etc/amnezia/amneziawg/{vpn}.conf"
    return env


def unit_active(unit: str) -> bool:
    rc, out, _ = run(["systemctl", "is-active", unit], timeout=10)
    return out.strip() in ("active", "activating")


def start_bg_unit(unit: str, cmd: list, logfile: str) -> tuple:
    """Запустить команду фоновым transient-юнитом с логом в файл.
    systemd-run --collect убирает юнит после завершения (даже failed)."""
    if unit_active(unit):
        return 1, "", "операция уже выполняется"
    open(logfile, "w").close()
    full = ["systemd-run", "--collect", f"--unit={unit}",
            "-p", f"StandardOutput=append:{logfile}",
            "-p", f"StandardError=append:{logfile}", "--"] + cmd
    return run(full, timeout=30)


def log_tail(logfile: str, lines: int = 14, width: int = 3200) -> str:
    try:
        data = open(logfile, encoding="utf-8", errors="ignore").read()
    except OSError:
        return "(лог пуст)"
    tail = "\n".join(data.splitlines()[-lines:])
    return tail[-width:] if tail else "(лог пуст)"


def read_status() -> dict:
    try:
        return json.load(open(STATUS_FILE, encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return {}


def write_status_flag(**kw):
    try:
        cur = read_status()
        cur.update(kw)
        json.dump(cur, open(STATUS_FILE, "w", encoding="utf-8"), ensure_ascii=False)
    except Exception:  # noqa: BLE001
        pass


async def watch_unit(c: CallbackQuery, unit: str, logfile: str, title: str,
                     done_note: str, back_cb: str = "upd:menu",
                     poll: float = 4.0, max_minutes: int = 95):
    """Живой прогресс: редактируем одно сообщение хвостом лога, пока юнит жив."""
    started = time.time()
    while unit_active(unit):
        if time.time() - started > max_minutes * 60:
            await show(c, f"{title}\n⚠️ Превышен лимит {max_minutes} мин — "
                          "смотри лог на сервере.", kb([back(back_cb)]))
            return
        await show(c, f"{title}\n<pre>{html.escape(log_tail(logfile))}</pre>",
                   kb([back(back_cb)]), stamp=True)
        await asyncio.sleep(poll)
    # юнит завершился (--collect убрал его; результат — по логу/статусу)
    await show(c, f"{title}\n<pre>{html.escape(log_tail(logfile))}</pre>\n\n{done_note}",
               kb([back(back_cb)]), stamp=True)


PHASE_RU = {"backup": "💾 бэкап клиентов", "clone": "📥 загрузка апстрима",
            "questions": "✍️ анкета", "installing": "⚙️ установка",
            "reintegrate": "🔁 возврат AWG 2.0", "done": "✅ завершено",
            "failed": "❌ ошибка"}


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
        [("🔄 Обновление", "upd:menu")],
        [("🛡 Обфускация", "obf:menu")],
        [("💾 Бэкап", "backup:run"), ("♻️ Восстановить", "restore:ask")],
    ])


def upd_menu() -> InlineKeyboardMarkup:
    return kb([
        [("📋 Обновить списки АнтиЗапрета", "upd:doall")],
        [("⬆️ Полное обновление AntiZapret", "upd:full")],
        [("🧬 Обновить AWG 2.0 (код слоя)", "upd:awg")],
        [("🛠 Перенастроить обфускацию", "reconf:preset")],
        back(),
    ])


def clients_menu() -> InlineKeyboardMarkup:
    return kb([
        [("➕ AmneziaWG 2.0", "awg:menu")],
        [("➕ Стоковый WG", "vanilla:add"), ("➕ OpenVPN", "ovpn:menu")],
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
    """Стоковый WG-клиент: отдаём только обфусцированные junk-only «-am» конфиги
    для обоих туннелей (antizapret split + vpn full). Plain-WG файлы не шлём."""
    sent = 0
    for svc, label in (("antizapret", "AntiZapret (split)"), ("vpn", "Полный VPN")):
        conf = find_vanilla_file(VANILLA_AM_DIR, svc, name, "-am.conf")
        if conf:
            await bot.send_document(chat, FSInputFile(conf, filename=os.path.basename(conf)),
                                    caption=f"📄 {label} — AmneziaWG (сток)")
            sent += 1
    if not sent:
        await bot.send_message(chat, "⚠️ «-am» конфиги стокового клиента не найдены.")


async def send_ovpn_files(chat: int, name: str):
    sent = 0
    for sub, label in (("antizapret", "split-routing"), ("vpn", "полный туннель")):
        conf = find_vanilla_file(OVPN_DIR, sub, name, ".ovpn")
        if conf:
            await bot.send_document(chat, FSInputFile(conf, filename=os.path.basename(conf)),
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
        await upd(f"⏳ Создаю стокового WG <b>{html.escape(name)}</b> (оба туннеля)…")
        # client.sh 4 создаёт клиента сразу в antizapret+vpn (split и full)
        rc, out, err = run_client_sh(["4", name])
        if rc != 0:
            return await upd(f"❌ {html.escape(err or out)[:900]}", main_menu())
        await send_vanilla_wg_files(m.chat.id, name)
        await upd(f"✅ Стоковый WG <b>{html.escape(name)}</b> готов "
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
        return await show(c, "Выбери клиента:\n🌐/🔒 AWG 2.0 · 🅰️ сток WG · 📄 OpenVPN",
                          kb(rows))

    if d.startswith("cli:"):
        _, svc, name = d.split(":", 2)
        tag = {"antizapret": "AmneziaWG 2.0 · AntiZapret", "vpn": "AmneziaWG 2.0 · Полный VPN",
               "vanilla": "Стоковый WG · AntiZapret + Полный VPN",
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

    # ═══ ОБНОВЛЕНИЕ ══════════════════════════════════════════════════════════

    if d == "upd:menu":
        return await show(c, "🔄 <b>Обновление</b>", upd_menu())

    # ── списки АнтиЗапрета (doall.sh) — быстро и безопасно
    if d == "upd:doall":
        logf = f"{LOG_DIR}/az-doall.log"
        rc, _, err = start_bg_unit("az-doall", ["bash", DOALL_SH], logf)
        if rc != 0:
            return await show(c, f"❌ {html.escape(err)[:400]}", kb([back("upd:menu")]))
        return await watch_unit(c, "az-doall", logf, "📋 <b>Обновление списков…</b>",
                                "✅ Списки обновлены (custom-хук обновил и правила AWG 2.0).")

    # ── полное обновление: предупреждение → префлайт → выбор режима → запуск
    if d == "upd:full":
        return await show(c, "⬆️ <b>Полное обновление AntiZapret</b>\n\n"
                          "Что произойдёт:\n"
                          "• клиенты сохранятся (бэкап → setup.sh восстановит сам);\n"
                          "• слой AmneziaWG 2.0 вернётся автоматически;\n"
                          "• в конце <b>сервер перезагрузится</b>, бот вернётся через "
                          "~2–3 минуты и отчитается.\n\n"
                          "Сначала проверю, не изменилась ли анкета апстрима.",
                          kb([[("🔍 Проверить и продолжить", "updfull:preflight")],
                              back("upd:menu")]))

    if d == "updfull:preflight":
        await show(c, "🔍 Проверяю анкету свежего setup.sh…", kb([back("upd:menu")]))
        rc, out, err = await asyncio.get_event_loop().run_in_executor(
            None, lambda: run([PY, RUNNER_PY, "preflight"], timeout=180))
        try:
            pf = json.loads(out)
        except Exception:  # noqa: BLE001
            pf = {"ok": False, "error": (err or out)[:300], "unknown": []}
        if pf.get("error"):
            return await show(c, f"❌ Префлайт: {html.escape(pf['error'])}",
                              kb([back("upd:menu")]))
        if pf.get("ok"):
            txt = (f"✅ Анкета известна полностью ({pf.get('total', '?')} вопросов).\n\n"
                   "Как отвечать?")
        else:
            unk = "\n".join(f"  • {html.escape(u)}" for u in pf.get("unknown", [])[:10])
            txt = (f"⚠️ Апстрим добавил незнакомые вопросы "
                   f"({len(pf.get('unknown', []))}):\n{unk}\n\n"
                   "На них будет принят <b>дефолт апстрима</b> (Enter). "
                   "Известные вопросы — как выберешь ниже:")
        return await show(c, txt, kb([
            [("📄 Как настроено сейчас", "updfull:go:current")],
            [("🆕 Все по умолчанию", "updfull:go:defaults")],
            back("upd:menu")]))

    if d.startswith("updfull:go:"):
        mode = d.split(":", 2)[2]
        logf = f"{LOG_DIR}/az-full-update.log"
        write_status_flag(phase="starting", reported=False)
        rc, _, err = start_bg_unit(
            "az-full-update",
            [PY, RUNNER_PY, "run", "--mode", mode,
             "--answers", ANSWERS_FILE, "--status", STATUS_FILE, "--log", logf], logf)
        if rc != 0:
            return await show(c, f"❌ {html.escape(err)[:400]}", kb([back("upd:menu")]))
        # свой прогресс-цикл: фазы из статус-файла + хвост лога
        title = "⬆️ <b>Полное обновление AntiZapret</b>"
        started = time.time()
        while unit_active("az-full-update") and time.time() - started < 95 * 60:
            st = read_status()
            phase = PHASE_RU.get(st.get("phase", ""), st.get("phase", "…"))
            extra = f" · ответов: {st['answered']}" if "answered" in st else ""
            await show(c, f"{title}\nФаза: {phase}{extra}\n"
                          f"<pre>{html.escape(log_tail(logf, 10))}</pre>",
                       kb([back("upd:menu")]), stamp=True)
            await asyncio.sleep(5)
        st = read_status()
        if st.get("phase") == "done":
            write_status_flag(reported=True)
            return await show(c, f"{title}\n\n✅ Готово! Сервер перезагрузится "
                              "через минуту, бот вернётся и подтвердит. "
                              + ("⚠️ Были незнакомые вопросы — принят дефолт."
                                 if st.get("had_unknown") else ""),
                              kb([back()]))
        return await show(c, f"{title}\n\n❌ {html.escape(str(st.get('error', 'см. лог')))}"
                          f"\n<pre>{html.escape(log_tail(logf, 10))}</pre>",
                          kb([back("upd:menu")]))

    # ── обновление кода слоя AWG 2.0 (install.sh --update)
    if d == "upd:awg":
        return await show(c, "🧬 <b>Обновление AWG 2.0</b>\n\n"
                          "Подтянет свежий код слоя и бота с GitHub. Обфускация, "
                          "порты и клиенты не меняются. В конце <b>бот "
                          "перезапустится</b> — итог пришлю после рестарта.",
                          kb([[("✅ Обновить", "updawg:go")], back("upd:menu")]))
    if d == "updawg:go":
        logf = f"{LOG_DIR}/az-awg-update.log"
        write_status_flag(awg_upd="running", awg_reported=False)
        marker_ok = f"python3 - <<'PYEOF'\nimport json\ns = {{}}\ntry: s = json.load(open('{STATUS_FILE}'))\nexcept Exception: pass\ns['awg_upd'] = 'ok'\njson.dump(s, open('{STATUS_FILE}', 'w'))\nPYEOF"
        marker_fail = marker_ok.replace("'ok'", "'fail'")
        script = (f"if curl -fsSL {INSTALL_SH_URL} | bash -s -- --update; "
                  f"then {marker_ok}\nelse {marker_fail}\nfi")
        rc, _, err = start_bg_unit("az-awg-update", ["bash", "-c", script], logf)
        if rc != 0:
            return await show(c, f"❌ {html.escape(err)[:400]}", kb([back("upd:menu")]))
        return await watch_unit(c, "az-awg-update", logf, "🧬 <b>Обновление AWG 2.0…</b>",
                                "Если бот перезапустился — итог придёт отдельным сообщением.")

    # ── перенастройка обфускации кнопками (порты и клиентские ключи не меняются)
    if d == "reconf:preset":
        return await show(c, "🛠 <b>Перенастройка обфускации</b>\nИнтенсивность:",
                          kb([[("router", "reconf:p:router"), ("low", "reconf:p:low")],
                              [("medium", "reconf:p:medium"), ("high", "reconf:p:high")],
                              [("paranoid", "reconf:p:paranoid")], back("upd:menu")]))
    if d.startswith("reconf:p:"):
        preset = d.split(":", 2)[2]
        return await show(c, f"Пресет <b>{preset}</b>. Мимикрия:",
                          kb([[("авто", f"reconf:t:{preset}:auto"),
                               ("quic", f"reconf:t:{preset}:quic"),
                               ("tls", f"reconf:t:{preset}:tls")],
                              [("web", f"reconf:t:{preset}:web"),
                               ("voip", f"reconf:t:{preset}:voip"),
                               ("dns", f"reconf:t:{preset}:dns")],
                              [("mixed", f"reconf:t:{preset}:mixed")],
                              back("reconf:preset")]))
    if d.startswith("reconf:t:"):
        _, _, preset, tpl = d.split(":", 3)
        await show(c, f"⏳ Применяю {preset}/{tpl}…", kb([back("upd:menu")]))
        args = [OBF_SH, "--preset", preset, "--fp", "chrome", "--apply"]
        if tpl != "auto":
            args[3:3] = ["--template", tpl]
        rc, out, err = run(args, timeout=180, env=obf_env())
        if rc != 0:
            return await show(c, f"❌ {html.escape(err or out)[:800]}", kb([back("upd:menu")]))
        run([CLIENT_SH, "regen-all"], timeout=300)
        return await show(c, f"✅ Профиль <b>{preset}/{tpl}</b> применён, конфиги "
                          "клиентов пересозданы.\n⚠️ Клиентам нужно переимпортировать "
                          "конфиги (Скачать конфиг → заново в приложение).\n"
                          "Порты и ключи не менялись.", kb([back("upd:menu")]))

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


async def report_pending():
    """После рестарта бота (перезагрузка сервера / обновление слоя) — отчитаться
    о завершившихся фоновых операциях, о которых не успели сообщить."""
    st = read_status()
    msgs = []
    if st.get("phase") == "done" and st.get("reboot_pending") and not st.get("reported"):
        extra = " ⚠️ Были незнакомые вопросы — принят дефолт апстрима." \
            if st.get("had_unknown") else ""
        msgs.append("✅ <b>Полное обновление AntiZapret завершено</b>, сервер "
                    "перезагружен, слой AmneziaWG 2.0 восстановлен." + extra)
        write_status_flag(reported=True, reboot_pending=False)
    elif st.get("phase") == "failed" and not st.get("reported"):
        msgs.append("❌ <b>Полное обновление AntiZapret не удалось</b>: "
                    f"{html.escape(str(st.get('error', '')))[:400]}\n"
                    "Лог: /var/log/az-full-update.log")
        write_status_flag(reported=True)
    if st.get("awg_upd") == "ok" and not st.get("awg_reported"):
        msgs.append("✅ <b>Слой AWG 2.0 обновлён</b>, бот перезапущен. "
                    "Клиенты и обфускация не менялись.")
        write_status_flag(awg_reported=True, awg_upd=None)
    elif st.get("awg_upd") == "fail" and not st.get("awg_reported"):
        msgs.append("❌ <b>Обновление AWG 2.0 не удалось.</b> "
                    "Лог: /var/log/az-awg-update.log")
        write_status_flag(awg_reported=True, awg_upd=None)
    for m in msgs:
        for admin in ADMINS:
            try:
                await bot.send_message(admin, m, parse_mode="HTML")
            except Exception:  # noqa: BLE001
                pass


async def main():
    from aiogram.types import BotCommand
    await bot.set_my_commands([BotCommand(command="start", description="Меню")])
    print(f"AntiZapret-AWG bot up. Admins: {sorted(ADMINS)}")
    await report_pending()
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
