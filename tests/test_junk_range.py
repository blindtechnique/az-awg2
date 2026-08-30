#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Окно junk-пакетов: Jmin < Jmax при любом MTU, и БЕЗ изменений на рабочем.

Две проверки, и вторая важнее первой.

1. Инвариант. Ядро берёт размер джанка как get_random_u32_inclusive(jmin, jmax),
   а этот хелпер требует floor <= ceil. Пару Jmin > Jmax не отвергает никто:
   ни утилиты, ни netlink (там голые NLA_U16 без сравнения). Раньше генератор
   восстанавливал инвариант ДО клампа по MTU, и кламп его же ломал:
   `--mtu 60 --preset paranoid` давал Jmin=24, Jmax=20.

2. Отсутствие изменений. Правка порядка не имеет права трогать значения на
   рабочем диапазоне MTU — иначе перевыпуск профиля на существующем сервере
   выдал бы другое окно, чем раньше. Проверяем точным равенством пресету.

  python3 tests/test_junk_range.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "overlay", "obfuscation"))

import awg_obfuscate as gen2      # noqa: E402
import awg3_obfuscate as gen3     # noqa: E402

fail = 0


def ok(msg):
    print("  ✔ %s" % msg)


def bad(msg, detail=""):
    global fail
    print("  ✘ %s" % msg)
    if detail:
        print("     %s" % detail)
    fail = 1


# Рабочий диапазон — тот, что принимает установщик. Ниже 576 туннель не
# соберётся ни у одного клиента, выше 1500 несущий интерфейс всё равно режет.
SANE = [576, 700, 1000, 1280, 1320, 1380, 1420, 1500]
# А это то, что может лежать в services.env со старых времён или прийти руками:
# установщик такое больше не принимает, но уже записанное мы не трогаем.
WILD = [575, 400, 200, 100, 72, 64, 63, 60, 41, 8, 1]

print("\n\033[1m1. Инвариант Jmin < Jmax держится при любом MTU\033[0m")
for name, mod in (("2.0", gen2), ("3.0", gen3)):
    broken = []
    for mtu in SANE + WILD:
        for preset in mod.PRESETS:
            d = mod.generate(preset, mtu=mtu)
            jmin, jmax = int(d["Jmin"]), int(d["Jmax"])
            if jmin < 1 or jmin >= jmax:
                broken.append("mtu=%s %s -> Jmin=%s Jmax=%s" % (mtu, preset, jmin, jmax))
    if broken:
        bad("слой %s: инвариант нарушен" % name, "; ".join(broken[:3]))
    else:
        ok("слой %s: %d сочетаний пресет x MTU" % (name, len(mod.PRESETS) * len(SANE + WILD)))

print("\n\033[1m2. На рабочем MTU значения те же, что и были\033[0m")
# Это и есть ответ на вопрос «не сломает ли уже выданные конфиги»: пресет
# описывает окно явными числами, кламп по MTU до них не дотягивается (самый
# широкий пресет — 400, а mtu-40 при MTU 576 это уже 536), поэтому перевыпуск
# профиля обязан дать ровно то же окно, что и до правки порядка.
for name, mod in (("2.0", gen2), ("3.0", gen3)):
    drift = []
    for mtu in SANE:
        for preset, p in mod.PRESETS.items():
            d = mod.generate(preset, mtu=mtu)
            want_min, want_max = int(p["jmin"]), int(p["jmax"])
            got_min, got_max = int(d["Jmin"]), int(d["Jmax"])
            if (got_min, got_max) != (want_min, want_max):
                drift.append("mtu=%s %s: ждали %s/%s, вышло %s/%s"
                             % (mtu, preset, want_min, want_max, got_min, got_max))
    if drift:
        bad("слой %s: окно изменилось" % name, "; ".join(drift[:3]))
    else:
        ok("слой %s: окно совпадает с пресетом на всех рабочих MTU" % name)

print("\n\033[1m3. Jc не затронут\033[0m")
# Jc — число джанк-пакетов, оно из своего диапазона и к MTU отношения не имеет.
# Проверяем, что правка не задела соседнюю строку.
for name, mod in (("2.0", gen2), ("3.0", gen3)):
    out = []
    for preset, p in mod.PRESETS.items():
        lo, hi = p["jc"] if isinstance(p["jc"], (list, tuple)) else (p["jc"], p["jc"])
        vals = [int(mod.generate(preset, mtu=1420)["Jc"]) for _ in range(20)]
        if not all(lo <= v <= hi for v in vals):
            out.append("%s: %s вне [%s, %s]" % (preset, sorted(set(vals)), lo, hi))
    if out:
        bad("слой %s: Jc вне диапазона пресета" % name, "; ".join(out))
    else:
        ok("слой %s: Jc в границах пресета" % name)

print("")
print("═══ ВСЁ ЗЕЛЁНОЕ ═══" if not fail else "═══ ЕСТЬ ПАДЕНИЯ ═══")
sys.exit(fail)
