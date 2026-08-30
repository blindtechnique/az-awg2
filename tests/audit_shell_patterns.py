#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Аудит shell-паттернов, на которых проект уже ломался.

Смысл не в том, чтобы запретить конструкции, а в том, чтобы ни одно новое их
появление не прошло молча. Каждое найденное место обязано быть либо
исправлено, либо внесено в tests/audit_allowlist.txt с письменным
обоснованием — почему именно здесь код возврата никуда не попадает.

Классы, каждый из которых уже стрелял в этом проекте:

  pipe-predicate    последняя стадия конвейера — grep -q или grep -m, то есть
                    код возврата И ЕСТЬ ответ. Под pipefail producer получает
                    SIGPIPE, конвейер отдаёт 141, и «нашли» читается как
                    «не нашли». Так занятый порт объявлялся свободным.
  pipe-fallible     в конвейере команда, для которой «ничего не нашлось» —
                    штатный ненулевой код (grep, ls, find, git, getent, ip
                    route get). Под pipefail он протаскивается наружу, под
                    set -e скрипт умирает молча, а заготовленная ветка «пусто»
                    становится недостижимой. Снимается через `|| true`.
  ss-fixed-column   жёсткий номер поля у ss: колонка Netid печатается не во
                    всех версиях iproute2. Так список занятых портов был пуст
                    ВСЕГДА. Локальный адрес — предпоследнее поле в любой
                    раскладке.
  colon-plus-flag   ${VAR:+…} на переменной, принимающей "0": ноль непустой,
                    подстановка срабатывает всегда — ровно наоборот задуманному.
  lost-exit-code    [ "$?" = N ] после команды: второй $? это код самого [.

Запуск:  python3 tests/audit_shell_patterns.py
Список исключений: tests/audit_allowlist.txt
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALLOWLIST = os.path.join(ROOT, "tests", "audit_allowlist.txt")

# Каталоги с кодом, который реально исполняется на сервере. Сами наборы не
# проверяем: они нарочно воспроизводят плохие конструкции, чтобы их измерить.
SCAN_DIRS = ["bin", "patches", "overlay", "."]
SKIP_DIRS = {"tests", ".git", ".github"}

# Команды, которые возвращают ненулевой код ШТАТНО, а не по аварии: «ничего не
# нашлось» для них — обычный ответ. Именно они превращают конвейер в мину под
# pipefail. printf, md5sum, basename, cut, tr, awk и sed сюда НЕ входят: они
# отдают 0 и на пустом входе, и ловить их — только засорять список исключений.
# awg и go добавлены по итогам разбора: `awg setconf` в конвейере убивал
# скрипт до уборки временного файла с приватным ключом сервера, а
# `go version` на битом GOROOT — до собственного сообщения об ошибке.
FALLIBLE = r"(grep|ls|find|git|getent|modinfo|dpkg|curl|wget|systemctl|lsmod|ip\s+route\s+get|awg\s+\w+|go\s+version)"

# 1. Конвейер-предикат: последняя стадия — grep -q или grep -m, то есть код
#    возврата И ЕСТЬ ответ. Под pipefail SIGPIPE от producer подменяет его на
#    141, и «нашли» читается как «не нашли».
PIPE_PREDICATE = re.compile(r"\|\s*grep\s+[^|]*-\w*(q|m\s*\d)")

# 2. Ненадёжная команда в конвейере, чей код кому-то виден: присваивание,
#    подстановка или просто отдельная команда. `|| true` снимает вопрос.
# Достаточно, чтобы в строке была труба И где-то в ней — ненадёжная команда:
# неважно, до первой трубы она стоит или после. Первый вариант правила требовал
# её после трубы и пропускал cpriv="$(grep … | head -1 | …)" — то самое место,
# из-за которого разбор и затевался.
PIPE_FALLIBLE = re.compile(r"^(?=[^#]*\|)[^#]*\b" + FALLIBLE + r"\b")

# 3. Жёсткий номер колонки у ss: раскладка зависит от версии iproute2.
SS_COLUMN = re.compile(r"ss\s+[^|]*\|\s*awk\s+'\{\s*print\s+\$\d")

# 4. Второй $? — это код самого [, настоящий уже потерян.
LOST_CODE = re.compile(r'\[\s*"\$\?"\s*=')

# 5. ${VAR:+…} на переменной-флаге: "0" непустой.
COLON_PLUS = re.compile(r"\$\{(?P<var>[A-Za-z_][A-Za-z_0-9]*):\+")

RULES = [
    ("pipe-predicate", PIPE_PREDICATE),
    ("pipe-fallible", PIPE_FALLIBLE),
    ("ss-fixed-column", SS_COLUMN),
    ("lost-exit-code", LOST_CODE),
]


def norm(code):
    """Ключ, устойчивый к переносу строки и правке отступов."""
    return re.sub(r"\s+", " ", code.strip())


def load_allowlist():
    """Формат строки:  <файл> :: <правило> :: <код> :: <обоснование>"""
    out = {}
    if not os.path.exists(ALLOWLIST):
        return out
    with open(ALLOWLIST, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("::")]
            if len(parts) != 4:
                sys.stderr.write("исключение без четырёх полей: %s\n" % line)
                sys.exit(2)
            path, rule, code, reason = parts
            if not reason:
                sys.stderr.write("исключение без обоснования: %s\n" % line)
                sys.exit(2)
            out[(path, rule, norm(code))] = reason
    return out


def shell_files():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in sorted(files):
            if name.endswith(".sh"):
                yield os.path.relpath(os.path.join(base, name), ROOT).replace("\\", "/")


def flag_vars(text):
    """Переменные, которым в этом же файле присваивают 0 или 1."""
    return set(re.findall(r"^\s*([A-Za-z_][A-Za-z_0-9]*)=[01]\b", text, re.M)) | \
           set(re.findall(r"\b([A-Za-z_][A-Za-z_0-9]*)=[01];", text))


def scan(path):
    full = os.path.join(ROOT, path)
    with open(full, encoding="utf-8") as fh:
        text = fh.read()
    flags = flag_vars(text)
    hits = []
    for num, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        stripped = line.strip()
        # Условие if/while и явный `|| …` — это места, где ненулевой код и
        # ЕСТЬ ответ, а не авария. Послабление только для pipe-fallible: он
        # про «скрипт умер». pipe-predicate про «ответ неверный», и в условии
        # это ровно так же плохо — там послаблений нет.
        handled = bool(re.match(r"(if|elif|while|until)\b", stripped)) or "||" in line
        for rule, rx in RULES:
            if rx.search(line):
                if rule == "pipe-fallible" and handled:
                    continue
                hits.append((rule, num, stripped))
        for m in COLON_PLUS.finditer(line):
            if m.group("var") in flags:
                hits.append(("colon-plus-flag", num, line.strip()))
    return hits


def main():
    allow = load_allowlist()
    used = set()
    unknown = []
    for path in shell_files():
        for rule, num, code in scan(path):
            key = (path, rule, norm(code))
            if key in allow:
                used.add(key)
                continue
            unknown.append((path, num, rule, code))

    stale = [k for k in allow if k not in used]

    if unknown:
        print("\n\033[1mНовые места без разбора\033[0m")
        for path, num, rule, code in unknown:
            print("  \033[1;31m✘\033[0m %s:%s  [%s]" % (path, num, rule))
            print("     %s" % code[:110])
        print("\n  Каждое надо либо исправить, либо внести в tests/audit_allowlist.txt")
        print("  строкой вида:  файл :: правило :: код :: почему здесь безопасно")

    if stale:
        print("\n\033[1mИсключения, которым больше нечего прикрывать\033[0m")
        for path, rule, code in stale:
            print("  \033[1;31m✘\033[0m %s  [%s]" % (path, rule))
            print("     %s" % code[:110])
        print("\n  Код изменился — удали эти строки, иначе список гниёт.")

    if not unknown and not stale:
        print("  \033[1;32m✔\033[0m разобраны все %d известных мест, новых нет" % len(allow))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
