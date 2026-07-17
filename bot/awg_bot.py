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
INSTALL_SH_URL = os.environ.get(
    "AWG_INSTALL_SH_URL",
    "https://raw.githubusercontent.com/blindtechnique/az-awg2/main/install.sh")
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
    azcfg_input = State()


# какой config-файл AntiZapret редактирует админ (chat_id → имя файла)
_azcfg_edit = {}


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


OVPN_STATUS_DIR = os.environ.get("AWG_OVPN_STATUS_DIR", "/etc/openvpn/server/logs")
OVPN_STATUS_FILES = ["antizapret-udp-status.log", "antizapret-tcp-status.log",
                     "vpn-udp-status.log", "vpn-tcp-status.log"]


def _human_bytes(n: int) -> str:
    f = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if f < 1024 or u == "TB":
            return f"{int(f)}B" if u == "B" else f"{f:.1f}{u}"
        f /= 1024
    return f"{f:.1f}TB"


def ovpn_status(name: str) -> str:
    """Статистика OpenVPN-клиента из status-логов AntiZapret (status-version 1).
    Секция CLIENT LIST: Common Name,Real Address,Bytes Received,Bytes Sent,
    Connected Since. Клиент может быть в нескольких файлах (udp/tcp ×
    antizapret/vpn) — суммируем и показываем, где подключён. История по
    OpenVPN не ведётся: статус-файл содержит только активные сессии."""
    import glob as _glob
    total_rx = total_tx = 0
    sessions = []
    files = [os.path.join(OVPN_STATUS_DIR, f) for f in OVPN_STATUS_FILES]
    files += _glob.glob(os.path.join(OVPN_STATUS_DIR, "*-status.log"))
    seen = set()
    for path in files:
        if path in seen or not os.path.exists(path):
            continue
        seen.add(path)
        tunnel = os.path.basename(path).replace("-status.log", "")
        try:
            lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
        except OSError:
            continue
        in_clients = False
        for ln in lines:
            if ln.startswith("OpenVPN CLIENT LIST"):
                in_clients = True
                continue
            if ln.startswith("ROUTING TABLE") or ln.startswith("GLOBAL STATS"):
                in_clients = False
                continue
            if not in_clients or ln.startswith(("Updated", "Common Name")) or "," not in ln:
                continue
            parts = ln.split(",")
            if len(parts) < 5 or parts[0] != name:
                continue
            try:
                rx, tx = int(parts[2]), int(parts[3])
            except ValueError:
                continue
            total_rx += rx
            total_tx += tx
            sessions.append((tunnel, parts[1].rsplit(":", 1)[0], parts[4], rx, tx))

    if not sessions:
        return (f"📄 <b>{name}</b> · OpenVPN ⚪️ офлайн\n"
                "Сейчас не подключён. OpenVPN показывает статистику только по "
                "активным сессиям — история не сохраняется.")
    out = [f"📄 <b>{name}</b> · OpenVPN 🟢 онлайн",
           f"Трафик сессий: ↓{_human_bytes(total_rx)} ↑{_human_bytes(total_tx)}", ""]
    for tunnel, ip, since, rx, tx in sessions:
        out.append(f"🔌 {tunnel} · <code>{ip}</code> · с {since}\n"
                   f"    ↓{_human_bytes(rx)} ↑{_human_bytes(tx)}")
    return "\n".join(out)


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
        [("⚙️ Настройки AntiZapret", "azcfg:menu")],
        [("🔄 Обновление", "upd:menu")],
        [("🛡 Обфускация", "obf:menu")],
        [("💾 Бэкап", "backup:run"), ("♻️ Восстановить", "restore:ask")],
    ])


def upd_menu() -> InlineKeyboardMarkup:
    return kb([
        [("🔎 Проверить обновления", "upd:check")],
        [("📋 Обновить списки АнтиЗапрета", "upd:doall")],
        [("🧬 Обновить AWG 2.0 (код слоя)", "upd:awg")],
        [("🛠 Перенастроить обфускацию", "reconf:preset")],
        back(),
    ])


def has_openvpn() -> bool:
    """OpenVPN установлен, если есть серверные конфиги AntiZapret."""
    import glob as _g
    return bool(_g.glob("/etc/openvpn/server/antizapret-*.conf")
                or _g.glob("/etc/openvpn/server/vpn-*.conf"))


def has_wireguard() -> bool:
    """Стоковый WireGuard установлен, если есть его серверные конфиги."""
    return os.path.exists("/etc/wireguard/antizapret.conf") \
        or os.path.exists("/etc/wireguard/vpn.conf")


def has_awg_layer() -> bool:
    """Наш слой AmneziaWG 2.0 установлен."""
    return os.path.exists(SERVICES_ENV)


def clients_menu() -> InlineKeyboardMarkup:
    # показываем только те типы клиентов, что реально доступны на сервере
    # (пользователь мог поставить AntiZapret без OpenVPN и/или без WireGuard)
    rows = []
    if has_awg_layer():
        rows.append([("➕ AmneziaWG 2.0", "awg:menu")])
    row2 = []
    if has_wireguard():
        row2.append(("➕ Стоковый WG", "vanilla:add"))
    if has_openvpn():
        row2.append(("➕ OpenVPN", "ovpn:menu"))
    if row2:
        rows.append(row2)
    # временные клиенты — только для слоя (наш механизм TTL) или OpenVPN
    if has_awg_layer() or has_openvpn():
        rows.append([("⏳ Временный клиент", "temp:menu")])
    rows.append([("📋 Список клиентов", "clients:list")])
    rows.append(back())
    return kb(rows)


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


def ensure_vanilla_client_dirs():
    """Ваниль НЕ делает mkdir для /root/antizapret/client/* — каталоги приходят
    из setup. Если их нет (старая установка, ручная чистка), рендер в client.sh
    падает на редиректе '>' с ERR-trap. Создаём заранее — это безопасно."""
    base = os.path.dirname(VANILLA_AM_DIR.rstrip("/"))
    for tree in ("amneziawg", "wireguard"):
        for svc in ("antizapret", "vpn"):
            os.makedirs(os.path.join(base, tree, svc), exist_ok=True)


def run_export(conf: str, name: str, outdir: str) -> tuple:
    """awg-export.py: сперва venv-python бота, при неудаче — системный python3
    (segno/qrcode могут стоять только в одном из них). Возвращает (rc, лог)."""
    cmd_tail = [EXPORT_PY, conf, "--name", name, "--outdir", outdir, "--all"]
    rc, out, err = run([PY] + cmd_tail, timeout=60)
    if rc != 0 and PY != "python3":
        rc, out, err = run(["python3"] + cmd_tail, timeout=60)
    return rc, (err or out or "").strip()


async def send_vanilla_wg_files(chat: int, name: str):
    """Стоковый WG-клиент: для обоих туннелей (antizapret split + vpn full)
    отдаём обфусцированный «-am» .conf, QR и ссылку vpn:// для приложения Amnezia.
    URI/QR генерим на лету через awg-export.py из готового -am конфига ванили.
    Если файлов нет — самолечение: mkdir каталогов + повторный client.sh 4
    (он идемпотентен: для существующего клиента ключи сохраняются, файлы
    профилей пересоздаются заново)."""
    def _find_all() -> dict:
        return {svc: find_vanilla_file(VANILLA_AM_DIR, svc, name, "-am.conf")
                for svc in ("antizapret", "vpn")}

    confs = _find_all()
    regen_tail = ""
    if not all(confs.values()):
        ensure_vanilla_client_dirs()
        rc, out, err = run_client_sh(["4", name])
        regen_tail = (err or out or "").strip()[-700:]
        confs = _find_all()

    sent = 0
    for svc, label in (("antizapret", "AntiZapret (split)"), ("vpn", "Полный VPN")):
        conf = confs.get(svc)
        if not conf:
            continue
        sent += 1
        await bot.send_document(chat, FSInputFile(conf, filename=os.path.basename(conf)),
                                caption=f"📄 {label} — AmneziaWG (сток)")
        # сгенерировать QR (.png) и vpn:// (.vpn + -vpn.png) рядом с конфигом
        base = os.path.splitext(conf)[0]                 # …/svc-name-(host)-am
        rc, elog = run_export(conf, os.path.basename(base), os.path.dirname(conf))
        qr, vpn = base + ".png", base + ".vpn"
        if rc != 0 and not (os.path.exists(qr) or os.path.exists(vpn)):
            hint = ("нет модуля QR — выполните: "
                    "<code>/opt/antizapret-awg/venv/bin/pip install segno</code>"
                    if "ModuleNotFoundError" in elog or "ImportError" in elog else "")
            await bot.send_message(
                chat, f"⚠️ {label}: QR/URI не сгенерированы. {hint}\n"
                      f"<code>{html.escape(elog[-500:])}</code>", parse_mode="HTML")
            continue
        if os.path.exists(qr):
            await bot.send_photo(chat, FSInputFile(qr),
                                 caption=f"📱 {label}: QR для AmneziaWG")
        if os.path.exists(vpn):
            uri = open(vpn, encoding="utf-8").read().strip()
            await bot.send_message(chat, f"🔗 <b>{label} — ссылка vpn://</b> (Amnezia):",
                                   parse_mode="HTML")
            for chunk in (uri[i:i + 3800] for i in range(0, len(uri), 3800)):
                await bot.send_message(chat, f"<code>{html.escape(chunk)}</code>",
                                       parse_mode="HTML")
    if not sent:
        msg = "⚠️ «-am» конфиги стокового клиента не найдены и пересоздать их не удалось."
        if not os.path.exists("/etc/wireguard/templates/antizapret-client-am.conf"):
            msg += ("\n\nПричина: на сервере нет шаблонов "
                    "<code>/etc/wireguard/templates/*-am.conf</code> — установленный "
                    "AntiZapret старой версии, без AmneziaWG-профилей. "
                    "Обновите AntiZapret из терминала (🔎 Проверка обновлений подскажет команду), "
                    "затем нажмите «Скачать» ещё раз.")
        elif regen_tail:
            msg += f"\n\nВывод client.sh:\n<code>{html.escape(regen_tail)}</code>"
        await bot.send_message(chat, msg, parse_mode="HTML")


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
                  + (f" · удалится через {ttl}" if ttl else ""))
        await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())
    elif kind == "vanilla":
        await upd(f"⏳ Создаю стокового WG <b>{html.escape(name)}</b> (оба туннеля)…")
        # client.sh 4 создаёт клиента сразу в antizapret+vpn (split и full)
        rc, out, err = run_client_sh(["4", name])
        if rc != 0:
            return await upd(f"❌ {html.escape(err or out)[:900]}", main_menu())
        await send_vanilla_wg_files(m.chat.id, name)
        await upd(f"✅ Стоковый WG <b>{html.escape(name)}</b> готов "
                  "(AntiZapret + Полный VPN)")
        await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())
    elif kind in ("ovpn", "temp_ovpn"):
        days = data["days"]
        await upd(f"⏳ Создаю OpenVPN <b>{html.escape(name)}</b> ({days}д)…")
        rc, out, err = run_client_sh(["1", name, days])
        if rc != 0:
            return await upd(f"❌ {html.escape(err or out)[:900]}", main_menu())
        await send_ovpn_files(m.chat.id, name)
        await upd(f"✅ OpenVPN <b>{html.escape(name)}</b> готов")
        await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())


async def ask_name(c: CallbackQuery, state: FSMContext, **data):
    await state.set_state(Flow.name)
    data["_mid"] = c.message.message_id      # чтобы дальше редактировать это же сообщение
    await state.set_data(data)
    await show(c, "✍️ Введи имя клиента (буквы, цифры, _ , -):",
               kb([[("✖️ Отмена", "menu:main")]]))


@dp.message(Flow.azcfg_input, F.text)
async def on_azcfg_input(m: Message, state: FSMContext):
    if not is_admin(m.chat.id):
        return
    which = _azcfg_edit.get(m.chat.id)
    await state.clear()
    if not which:
        return await m.answer(menu_header(), parse_mode="HTML", reply_markup=main_menu())
    path = f"/root/antizapret/config/{which}.txt"
    try:
        existing = ([l.rstrip("\n") for l in open(path, encoding="utf-8")]
                    if os.path.exists(path) else [])
    except OSError:
        existing = []
    added, removed = 0, 0
    for raw in m.text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("-"):
            tgt = line[1:].strip()
            if tgt in existing:
                existing = [x for x in existing if x != tgt]
                removed += 1
        elif line not in existing:
            existing.append(line)
            added += 1
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(existing) + ("\n" if existing else ""))
    except OSError as e:
        return await m.answer(f"❌ Не удалось записать: {e}")
    await m.answer(f"✅ <b>{which}.txt</b>: добавлено {added}, удалено {removed}.\n"
                   "Чтобы применить — «📋 Обновить списки».",
                   parse_mode="HTML",
                   reply_markup=kb([[("📋 Обновить списки", "upd:doall")],
                                    [("⚙️ К настройкам", "azcfg:menu")]]))


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
        return await show(c, "Выбери клиента:\n"
                          "🌐 AWG 2.0 · AntiZapret (split)   🔒 AWG 2.0 · полный VPN\n"
                          "🅰️ сток WG   📄 OpenVPN",
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
            # живые сессии (гео/IP/трафик сейчас) + накопленная история из БД
            live = ovpn_status(name)
            hist = stats("client", name, "openvpn")
            body = live
            if hist and "не найден" not in hist:
                body = live + "\n\n— — —\n" + hist
            return await show(c, body,
                              kb([[("🔄 Обновить", f"clinfo:{svc}:{name}")],
                                  [("⬅️ Назад", f"cli:{svc}:{name}")]]), stamp=True)
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
                run_export(conf, f"{svc}-{name}", os.path.dirname(conf))
            await send_awg_files(c.message.chat.id, svc, name)
        # после файлов — заново открыть меню отдельным сообщением
        await bot.send_message(c.message.chat.id, menu_header(),
                               parse_mode="HTML", reply_markup=main_menu())
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
        rows = []
        if has_awg_layer():
            rows.append([("🌐 AWG AntiZapret", "temptype:antizapret")])
            rows.append([("🔒 AWG Полный VPN", "temptype:vpn")])
        if has_openvpn():
            rows.append([("📄 OpenVPN", "temptype:ovpn")])
        rows.append(back("clients:menu"))
        return await show(c, "Временный клиент — тип:", kb(rows))
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

    if d == "upd:check":
        await show(c, "🔎 Проверяю изменения кода на GitHub…", kb([back("upd:menu")]))
        rc, out, err = await asyncio.get_event_loop().run_in_executor(
            None, lambda: run([PY, RUNNER_PY, "check-updates"], timeout=90))
        try:
            ch = json.loads(out)
        except Exception:  # noqa: BLE001
            return await show(c, f"❌ Не удалось проверить: {html.escape((err or out)[:300])}",
                              kb([back("upd:menu")]))
        az, lay = ch.get("antizapret", {}), ch.get("layer", {})

        def _line(name, info, action):
            if not info.get("known"):
                return f"• {name}: не с чем сравнить (обновись — запомню версию)"
            if info.get("changed"):
                return f"• {name}: 🟢 есть изменения кода → {action}"
            return f"• {name}: ✅ актуально, обновлять не обязательно"

        txt = ("🔎 <b>Проверка обновлений (код, не списки)</b>\n\n"
               + _line("AntiZapret", az, "обнови из терминала (см. ниже)") + "\n"
               + _line("Слой AWG 2.0", lay, "кнопка «Обновить AWG 2.0»") + "\n\n"
               "Полное обновление AntiZapret делается штатной командой в терминале "
               "сервера:\n<code>bash &lt;(wget -qO- --no-hsts --inet4-only "
               "https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/"
               "setup.sh)</code>\n\n"
               "Списки блокировок — отдельной кнопкой «Обновить списки».")
        return await show(c, txt, kb([back("upd:menu")]))

    # ═══ НАСТРОЙКИ ANTIZAPRET (штатные функции GubernievS) ═══════════════════

    if d == "azcfg:menu":
        rows = []
        if has_openvpn():
            rows.append([("🩹 Патч OpenVPN (анти-цензура)", "azcfg:patch")])
            rows.append([("⚡ OpenVPN DCO вкл/выкл", "azcfg:dco")])
        rows.append([("📝 include-hosts (в туннель)", "azcfg:edit:include-hosts")])
        rows.append([("📝 exclude-hosts (мимо туннеля)", "azcfg:edit:exclude-hosts")])
        rows.append([("📝 include-ips (IP в туннель)", "azcfg:edit:include-ips")])
        rows.append(back())
        note = ("⚙️ <b>Настройки AntiZapret</b>\n"
                "Штатные функции. Правки списков хостов/IP применяются после "
                "«🔄 Обновление → 📋 Обновить списки».")
        if not has_openvpn():
            note += "\n\n(OpenVPN не установлен — патч и DCO скрыты.)"
        return await show(c, note, kb(rows))

    if d == "azcfg:patch":
        return await show(c, "🩹 <b>Анти-цензурный патч OpenVPN</b> (только UDP)\n"
                          "0) Нет — снять патч\n"
                          "1) Strong — рекомендуется\n"
                          "2) Error-free — если Strong рвёт связь (роутеры MikroTik)",
                          kb([[("0", "azcfg:patchset:0"), ("1", "azcfg:patchset:1"),
                               ("2", "azcfg:patchset:2")], back("azcfg:menu")]))
    if d.startswith("azcfg:patchset:"):
        val = d.split(":")[2]
        logf = f"{LOG_DIR}/az-patch-openvpn.log"
        rc, _, err = start_bg_unit("az-patch-openvpn",
                                   ["bash", "/root/antizapret/patch-openvpn.sh", val], logf)
        if rc != 0:
            return await show(c, f"❌ {html.escape(err)[:300]}", kb([back("azcfg:menu")]))
        return await watch_unit(c, "az-patch-openvpn", logf,
                                f"🩹 <b>Патч OpenVPN → {val}…</b>",
                                "✅ Готово (клиентам может понадобиться переподключение).",
                                back_cb="azcfg:menu")

    if d == "azcfg:dco":
        return await show(c, "⚡ <b>OpenVPN DCO</b> (Data Channel Offload, ускорение)\n"
                          "Требуется OpenVPN 2.7.",
                          kb([[("Включить", "azcfg:dcoset:y"),
                               ("Выключить", "azcfg:dcoset:n")], back("azcfg:menu")]))
    if d.startswith("azcfg:dcoset:"):
        val = d.split(":")[2]
        logf = f"{LOG_DIR}/az-dco.log"
        rc, _, err = start_bg_unit("az-dco",
                                   ["bash", "/root/antizapret/openvpn-dco.sh", val], logf)
        if rc != 0:
            return await show(c, f"❌ {html.escape(err)[:300]}", kb([back("azcfg:menu")]))
        return await watch_unit(c, "az-dco", logf,
                                f"⚡ <b>DCO → {'вкл' if val=='y' else 'выкл'}…</b>",
                                "✅ Готово.", back_cb="azcfg:menu")

    if d.startswith("azcfg:edit:"):
        which = d.split(":", 2)[2]
        path = f"/root/antizapret/config/{which}.txt"
        cur = ""
        try:
            cur = open(path, encoding="utf-8").read().strip()
        except OSError:
            pass
        shown = cur if cur else "(пусто)"
        if len(shown) > 1500:
            shown = shown[:1500] + "\n…(первые 1500 символов)"
        titles = {"include-hosts": "домены В туннель",
                  "exclude-hosts": "домены МИМО туннеля",
                  "include-ips": "IP/подсети В туннель"}
        return await show(c, f"📝 <b>{which}.txt</b> — {titles.get(which, '')}\n\n"
                          f"<pre>{html.escape(shown)}</pre>\n\n"
                          "После правок нужно «📋 Обновить списки».",
                          kb([[("➕ Добавить строки", f"azcfg:add:{which}")],
                              [("🗑 Очистить файл", f"azcfg:clear:{which}")],
                              back("azcfg:menu")]))

    if d.startswith("azcfg:add:"):
        which = d.split(":", 2)[2]
        _azcfg_edit[c.from_user.id] = which
        await state.set_state(Flow.azcfg_input)
        return await show(c, f"✏️ Пришли строки для добавления в <b>{which}.txt</b> "
                          "(каждая с новой строки). Строка вида «-значение» — удалить её.",
                          kb([back("azcfg:menu")]))

    if d.startswith("azcfg:clear:"):
        which = d.split(":", 2)[2]
        path = f"/root/antizapret/config/{which}.txt"
        try:
            open(path, "w", encoding="utf-8").close()
        except OSError as e:
            return await show(c, f"❌ {e}", kb([back("azcfg:menu")]))
        return await show(c, f"🗑 <b>{which}.txt</b> очищен.\n"
                          "Применится после «📋 Обновить списки».",
                          kb([[("📋 Обновить списки сейчас", "upd:doall")],
                              back("azcfg:menu")]))

    # ── списки АнтиЗапрета (doall.sh) — быстро и безопасно
    if d == "upd:doall":
        logf = f"{LOG_DIR}/az-doall.log"
        rc, _, err = start_bg_unit("az-doall", ["bash", DOALL_SH], logf)
        if rc != 0:
            return await show(c, f"❌ {html.escape(err)[:400]}", kb([back("upd:menu")]))
        return await watch_unit(c, "az-doall", logf, "📋 <b>Обновление списков…</b>",
                                "✅ Списки обновлены (custom-хук обновил и правила AWG 2.0).")

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
    о завершившихся фоновых операциях. Флаг reported ставится ТОЛЬКО после
    успешной отправки: сразу после ребута сеть может быть не готова, поэтому
    ждём и повторяем — иначе отчёт потеряется навсегда."""
    st = read_status()
    # (сообщение, каким флагом пометить после успешной отправки)
    jobs = []
    if st.get("awg_upd") == "ok" and not st.get("awg_reported"):
        jobs.append(("✅ <b>Слой AWG 2.0 обновлён</b>, бот перезапущен. "
                     "Клиенты и обфускация не менялись.",
                     dict(awg_reported=True, awg_upd=None)))
    elif st.get("awg_upd") == "fail" and not st.get("awg_reported"):
        jobs.append(("❌ <b>Обновление AWG 2.0 не удалось.</b> "
                     "Лог: /var/log/az-awg-update.log",
                     dict(awg_reported=True, awg_upd=None)))
    if not jobs:
        return
    for text, flag in jobs:
        sent = False
        for attempt in range(30):                 # до ~5 минут ожидания сети
            for admin in ADMINS:
                try:
                    await bot.send_message(admin, text, parse_mode="HTML")
                    sent = True
                except Exception:  # noqa: BLE001
                    pass
            if sent:
                write_status_flag(**flag)          # помечаем ТОЛЬКО после отправки
                break
            await asyncio.sleep(10)


async def main():
    from aiogram.types import BotCommand
    await bot.set_my_commands([BotCommand(command="start", description="Меню")])
    print(f"AntiZapret-AWG bot up. Admins: {sorted(ADMINS)}")
    # в фоне: ретраи ожидания сети не должны задерживать старт polling
    asyncio.create_task(report_pending())
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
