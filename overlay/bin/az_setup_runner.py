#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
az_setup_runner.py — полное обновление ванильного AntiZapret из Telegram-бота.

Прогоняет свежий setup.sh Губерниева, отвечая на его интерактивную анкету
через pexpect. Запускается ботом под systemd-run (переживает рестарт бота).

Режимы:
  preflight   скачать свежий setup.sh, извлечь все промпты анкеты и сравнить
              с картой известных вопросов. JSON в stdout:
              {"ok": true/false, "unknown": [...], "known": N, "sha256": "..."}
              Ничего не устанавливает и не ломает — чистый анализ текста.
  run         полное обновление:
              1) client.sh 8 → бэкап клиентов в /root/ (setup.sh сам его
                 подхватит и восстановит пользователей — штатная механика);
              2) git clone апстрима + обход просроченного GPG-ключа OpenVPN;
              3) нейтрализация финального `reboot` в setup.sh;
              4) прогон setup.sh под pexpect: ответы из /root/antizapret/setup
                 (режим current) или дефолты Enter (режим defaults), поверх —
                 overrides из файла --answers (KEY=VALUE, пишет бот);
              5) awg-reintegrate (возврат слоя AmneziaWG 2.0);
              6) отложенная перезагрузка (shutdown -r +1) — у бота есть минута
                 сообщить «готово, перезагружаюсь».

ВАЖНО про readline: промпты setup.sh используют `read -e -i <default>` —
поле УЖЕ предзаполнено дефолтом. Чтобы дать свой ответ, сначала шлём Ctrl-U
(стереть строку), затем значение. Просто «y\\r» превратилось бы в «yy».

Статус пишется в JSON-файл (--status) на каждом шаге: бот читает его для
прогресса и для отчёта после перезагрузки.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

UPSTREAM = "https://github.com/GubernievS/AntiZapret-VPN.git"
WORKDIR = "/tmp/az-full-update"
DEFAULT_STATUS = "/opt/antizapret-awg/az-update-status.json"
DEFAULT_LOG = "/var/log/az-full-update.log"
VANILLA_SETUP_FILE = "/root/antizapret/setup"       # сохранённые ответы прошлой установки
CLIENT_SH = "/root/antizapret/client.sh"
REINTEGRATE = "/opt/antizapret-awg/awg-reintegrate.sh"

# ── карта известных промптов анкеты setup.sh ─────────────────────────────────
# (regex по тексту промпта БЕЗ ANSI-эскейпов, имя переменной из /root/antizapret/setup)
PROMPT_MAP = [
    (r"Enable OpenVPN UDP\?",                         "OPENVPN_UDP_ENABLE"),
    (r"Enable OpenVPN TCP\?",                         "OPENVPN_TCP_ENABLE"),
    (r"Enable WireGuard/AmneziaWG\?",                 "WIREGUARD_ENABLE"),
    (r"Version choice \[0-2\]",                       "OPENVPN_PATCH"),
    (r"Turn on OpenVPN DCO\?",                        "OPENVPN_DCO"),
    (r"Use Cloudflare WARP for .*AntiZapret VPN",     "ANTIZAPRET_WARP"),
    (r"Use Cloudflare WARP for .*full VPN",           "VPN_WARP"),
    (r"DNS choice \[1-6\]",                           "ANTIZAPRET_DNS"),
    (r"DNS choice \[1-8\]",                           "VPN_DNS"),
    (r"blocking ads, trackers, malware",              "BLOCK_ADS"),
    (r"alternative CLIENT IP address range",          "ALTERNATIVE_CLIENT_IP"),
    (r"alternative range of FAKE IP",                 "ALTERNATIVE_FAKE_IP"),
    (r"TCP ports 80, 443, 504, 508 as backup",        "OPENVPN_BACKUP_TCP"),
    (r"UDP ports 80, 443, 504, 508 as backup",        "OPENVPN_BACKUP_UDP"),
    (r"UDP ports 540, 580 as backup",                 "WIREGUARD_BACKUP"),
    (r"multiple clients connecting to OpenVPN",       "OPENVPN_DUPLICATE"),
    (r"detailed logs in OpenVPN",                     "OPENVPN_LOG"),
    (r"SSH brute-force protection",                   "SSH_PROTECTION"),
    (r"network attack protection",                    "ATTACK_PROTECTION"),
    (r"network scan protection",                      "SCAN_PROTECTION"),
    (r"torrent guard",                                "TORRENT_GUARD"),
    (r"Restrict forwarding",                          "RESTRICT_FORWARD"),
    (r"client and server isolation",                  "CLIENT_ISOLATION"),
    (r"domain name for this OpenVPN server",          "OPENVPN_HOST"),
    (r"domain name for this WireGuard/AmneziaWG",     "WIREGUARD_HOST"),
    (r"Route all traffic for domains",                "ROUTE_ALL"),
    (r"Discord voice IPs",                            "DISCORD_INCLUDE"),
    (r"Cloudflare IPs",                               "CLOUDFLARE_INCLUDE"),
    (r"Telegram IPs",                                 "TELEGRAM_INCLUDE"),
    (r"WhatsApp IPs",                                 "WHATSAPP_INCLUDE"),
    (r"Roblox IPs",                                   "ROBLOX_INCLUDE"),
    # закомментированы в текущем setup.sh, но переменные существуют — если
    # апстрим их вернёт, ответим сохранёнными значениями, а не «неизвестный»
    (r"Amazon IPs",                                   "AMAZON_INCLUDE"),
    (r"Hetzner IPs",                                  "HETZNER_INCLUDE"),
    (r"DigitalOcean IPs",                             "DIGITALOCEAN_INCLUDE"),
    (r"OVH IPs",                                      "OVH_INCLUDE"),
    (r"Google IPs",                                   "GOOGLE_INCLUDE"),
    (r"Akamai IPs",                                   "AKAMAI_INCLUDE"),
]


def log_line(logf, msg):
    line = f"[runner {time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    if logf:
        logf.write(line + "\n")
        logf.flush()


def write_status(path, **kw):
    kw["ts"] = int(time.time())
    tmp = path + ".tmp"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        cur = {}
        if os.path.exists(path):
            try:
                cur = json.load(open(path, encoding="utf-8"))
            except Exception:  # noqa: BLE001
                cur = {}
        cur.update(kw)
        json.dump(cur, open(tmp, "w", encoding="utf-8"), ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:  # noqa: BLE001
        pass


def sh(cmd, timeout=600, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)


# ── извлечение промптов из текста setup.sh (для preflight) ───────────────────

ANSI_RE = re.compile(r"\\001|\\002|\\e\[[0-9;]*m|\x01|\x02|\x1b\[[0-9;]*m")
# read -rp <quoted>: '...', $'...' или "..."
READ_RE = re.compile(
    r"""read\s+(?:-[a-z]+\s+)*-r?p\s+(\$?'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")""")


def extract_prompts(setup_text: str) -> list:
    """Все тексты промптов анкеты, очищенные от ANSI и кавычек."""
    prompts = []
    for line in setup_text.splitlines():
        s = line.strip()
        if s.startswith("#"):                    # закомментированные вопросы не в счёт
            continue
        m = READ_RE.search(s)
        if not m:
            continue
        q = m.group(1)
        if q.startswith("$'"):
            q = q[2:-1]
        else:
            q = q[1:-1]
        q = ANSI_RE.sub("", q).replace("\\'", "'").strip()
        if q:
            prompts.append(q)
    return prompts


def preflight(logf=None) -> dict:
    """Скачать свежий setup.sh и сравнить анкету с PROMPT_MAP."""
    r = sh(["curl", "-fsSL", "--retry", "3",
            "https://raw.githubusercontent.com/GubernievS/AntiZapret-VPN/main/setup.sh"],
           timeout=120)
    if r.returncode != 0 or not r.stdout:
        return {"ok": False, "error": "не удалось скачать setup.sh апстрима",
                "unknown": [], "known": 0}
    text = r.stdout
    prompts = extract_prompts(text)
    unknown = [p for p in prompts
               if not any(re.search(rx, p) for rx, _ in PROMPT_MAP)]
    res = {"ok": len(unknown) == 0, "unknown": unknown, "known": len(prompts) - len(unknown),
           "total": len(prompts), "sha256": hashlib.sha256(text.encode()).hexdigest()[:16]}
    if logf:
        log_line(logf, f"preflight: {res['known']}/{res['total']} промптов известны, "
                       f"неизвестных: {len(unknown)}")
    return res


# ── ответы анкеты ────────────────────────────────────────────────────────────

def load_env_file(path: str) -> dict:
    vals = {}
    try:
        for line in open(path, encoding="utf-8", errors="ignore"):
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return vals


def build_answers(mode: str, answers_file: str) -> dict:
    """current → ответы из /root/antizapret/setup; defaults → пусто (Enter).
    Поверх обоих — overrides из файла бота."""
    ans = {}
    if mode == "current":
        ans.update(load_env_file(VANILLA_SETUP_FILE))
    if answers_file and os.path.exists(answers_file):
        ans.update(load_env_file(answers_file))
    # служебные поля из setup-файла ванили ответами не являются
    for k in ("SETUP_DATE", "CLEAR_HOSTS", "TXQUEUELEN", "MTU", "SEGMENTATION_OFFLOAD",
              "DEFAULT_INTERFACE", "DEFAULT_IP", "ANTIZAPRET_OUT_INTERFACE",
              "ANTIZAPRET_OUT_IP", "VPN_OUT_INTERFACE", "VPN_OUT_IP",
              "CLIENT_IP", "FAKE_IP"):
        ans.pop(k, None)
    return ans


# ── основной прогон ──────────────────────────────────────────────────────────

def do_run(mode: str, answers_file: str, status: str, logpath: str) -> int:
    try:
        import pexpect
    except ImportError:
        write_status(status, phase="failed", error="pexpect не установлен "
                     "(pip install pexpect в venv бота)")
        return 1

    logf = open(logpath, "a", encoding="utf-8")
    answers = build_answers(mode, answers_file)
    write_status(status, phase="backup", mode=mode, reported=False, error=None)
    log_line(logf, f"режим ответов: {mode}, переопределений: "
                   f"{len(load_env_file(answers_file)) if answers_file else 0}")

    # 1) бэкап клиентов — setup.sh штатно восстановит их из /root/backup*.tar.gz
    log_line(logf, "client.sh 8 — бэкап клиентов…")
    r = sh([CLIENT_SH, "8"], timeout=300)
    moved = False
    for f in sorted(os.listdir("/root/antizapret")):
        if f.startswith("backup-") and f.endswith(".tar.gz"):
            shutil.copy2(os.path.join("/root/antizapret", f), os.path.join("/root", f))
            moved = True
            log_line(logf, f"бэкап клиентов: /root/{f} (setup.sh восстановит сам)")
    if not moved:
        write_status(status, phase="failed",
                     error="client.sh 8 не создал бэкап — обновление прервано, "
                           "чтобы не потерять клиентов")
        log_line(logf, f"ОШИБКА бэкапа: rc={r.returncode} {r.stderr[:300]}")
        return 1

    # 2) свежий апстрим + обход просроченного GPG-ключа OpenVPN/knot
    write_status(status, phase="clone")
    log_line(logf, "клонирую апстрим…")
    shutil.rmtree(WORKDIR, ignore_errors=True)
    r = sh(["git", "clone", "--depth", "1", UPSTREAM, WORKDIR], timeout=300)
    if r.returncode != 0:
        write_status(status, phase="failed", error=f"git clone: {r.stderr[:300]}")
        return 1
    setup_path = os.path.join(WORKDIR, "setup.sh")
    text = open(setup_path, encoding="utf-8").read()
    text = text.replace("[signed-by=", "[trusted=yes signed-by=")
    text = text.replace("curl -fL --connect-timeout 30",
                        "curl -fL --connect-timeout 30 --retry 6 --retry-delay 3 --retry-all-errors")
    # 3) нейтрализуем финальный reboot: перезагрузимся сами, дав боту отчитаться
    text = re.sub(r"^reboot\s*$", 'echo "AZ_RUNNER_REBOOT_REQUIRED"', text, flags=re.M)
    open(setup_path, "w", encoding="utf-8").write(text)
    log_line(logf, "патчи применены: GPG-обход, ретраи curl, отложенный reboot")

    # 4) setup.sh под pexpect
    write_status(status, phase="questions", answered=0)
    child = pexpect.spawn("bash", ["setup.sh"], cwd=WORKDIR, encoding="utf-8",
                          codec_errors="replace", timeout=180,
                          dimensions=(40, 200), env={**os.environ, "TERM": "dumb"})
    child.logfile_read = logf

    compiled = [(re.compile(rx), var) for rx, var in PROMPT_MAP]
    # generic-хвосты ловят промпт-строку целиком (всё, что накопилось до курсора)
    patterns = [rx for rx, _ in compiled] + [
        r"\[y/n\]: ",                     # неизвестный y/n
        r"choice \[[0-9-]+\]: ",          # неизвестный выбор из списка
        r"press Enter to skip: ",         # неизвестный free-text
        pexpect.EOF,
        pexpect.TIMEOUT,
    ]
    n_known = len(compiled)
    answered = 0
    install_phase = False
    hard_deadline = time.time() + 90 * 60          # общий потолок 90 минут

    def send_answer(val: str):
        """Отправить ответ и СЪЕСТЬ ЭХО readline. При Ctrl-U readline
        перерисовывает промпт — без consume expect матчит собственное эхо как
        новый вопрос и вся анкета съезжает на один (найдено тестами)."""
        child.send(("\x15" + val + "\r") if val else "\r")
        try:
            child.expect("\r\n", timeout=10)       # до конца строки ввода
        except Exception:  # noqa: BLE001
            pass

    while True:
        if time.time() > hard_deadline:
            child.terminate(force=True)
            write_status(status, phase="failed", error="превышен лимит 90 минут")
            return 1
        try:
            idx = child.expect(patterns, timeout=120)
        except Exception as e:  # noqa: BLE001
            write_status(status, phase="failed", error=f"pexpect: {e}")
            return 1

        if idx < n_known:                                     # известный промпт
            var = compiled[idx][1]
            val = answers.get(var, "")
            send_answer(val)
            answered += 1
            write_status(status, phase="questions", answered=answered)
            log_line(logf, f"  → {var} = {val or '(default)'}")
        elif idx < n_known + 3:                               # неизвестный промпт
            send_answer("")
            answered += 1
            log_line(logf, "  → ⚠️ НЕИЗВЕСТНЫЙ ВОПРОС — принят дефолт (Enter)")
            write_status(status, phase="questions", answered=answered, had_unknown=True)
        elif patterns[idx] is pexpect.EOF:                    # setup.sh завершился
            break
        else:                                                  # TIMEOUT: идёт установка
            if not install_phase:
                install_phase = True
                write_status(status, phase="installing", answered=answered)
                log_line(logf, f"анкета пройдена ({answered} ответов), идёт установка…")
            continue

    child.close()
    ok = (child.exitstatus == 0)
    tail = ""
    try:
        tail = open(logpath, encoding="utf-8", errors="ignore").read()[-4000:]
    except OSError:
        pass
    if not ok and "AZ_RUNNER_REBOOT_REQUIRED" not in tail:
        write_status(status, phase="failed",
                     error=f"setup.sh завершился с кодом {child.exitstatus}")
        return 1

    # 5) вернуть слой AmneziaWG 2.0 (drop-in на antizapret.service тоже сработает,
    #    но прогоняем явно и дожидаемся)
    write_status(status, phase="reintegrate", answered=answered)
    log_line(logf, "awg-reintegrate — возврат слоя AmneziaWG 2.0…")
    sh([REINTEGRATE], timeout=300)

    # 5a) КРИТИЧНО для альтернативных диапазонов (172.x / 198.18.x): split-routing
    # в клиентских конфигах опирается на /etc/wireguard/ips (там FAKE_IP-диапазон),
    # который setup.sh перегенерировал под текущие ответы. Старые клиентские .conf
    # содержат прежние AllowedIPs → после смены диапазона split ломается. Поэтому
    # пересобираем клиентов слоя из свежего ips-файла.
    reg = sh(["/opt/antizapret-awg/client-awg.sh", "regen-all"], timeout=300)
    log_line(logf, f"regen-all клиентов слоя: rc={reg.returncode}")

    # 5b) верификация split-routing: up.sh должен был поставить ANTIZAPRET-MAPPING
    # и CONNMARK для клиентской подсети. Если их нет — предупреждаем в отчёте
    # (не рушим: сервер уедет в reboot, где up.sh отработает начисто).
    split_ok = True
    try:
        rules = sh(["iptables", "-w", "-t", "nat", "-S"], timeout=30).stdout
        if "ANTIZAPRET-MAPPING" not in rules:
            split_ok = False
    except Exception:  # noqa: BLE001
        pass
    if not split_ok:
        log_line(logf, "⚠️ ANTIZAPRET-MAPPING не найден до reboot — проверится после")

    # 6) отложенная перезагрузка: минута на отчёт бота
    write_status(status, phase="done", answered=answered, reboot_pending=True,
                 reported=False, split_ok=split_ok,
                 alt_ip=(build_answers(mode, answers_file).get("ALTERNATIVE_CLIENT_IP") == "y"))
    log_line(logf, "✅ обновление завершено, перезагрузка через 1 минуту (shutdown -r +1)")
    sh(["shutdown", "-r", "+1", "AntiZapret full update — reboot"], timeout=30)
    return 0


def dump_current() -> dict:
    """Текущие ответы анкеты из /root/antizapret/setup — для показа/редактирования
    в боте перед полным обновлением. Возвращает {VAR: value} по известным вопросам."""
    cur = load_env_file(VANILLA_SETUP_FILE)
    known_vars = {var for _, var in PROMPT_MAP}
    return {k: v for k, v in cur.items() if k in known_vars}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["preflight", "run", "dump-current"])
    ap.add_argument("--mode", choices=["current", "defaults"], default="current")
    ap.add_argument("--answers", default="/opt/antizapret-awg/setup-answers.env")
    ap.add_argument("--status", default=DEFAULT_STATUS)
    ap.add_argument("--log", default=DEFAULT_LOG)
    a = ap.parse_args()
    if a.action == "preflight":
        print(json.dumps(preflight(), ensure_ascii=False))
        return 0
    if a.action == "dump-current":
        print(json.dumps(dump_current(), ensure_ascii=False))
        return 0
    return do_run(a.mode, a.answers, a.status, a.log)


if __name__ == "__main__":
    sys.exit(main())
