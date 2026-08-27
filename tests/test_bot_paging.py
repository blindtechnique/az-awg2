# -*- coding: utf-8 -*-
"""Приёмка разбивки на страницы: параметры берутся из боевого файла."""
import io, os, re, sys

# tests/ лежит внутри репозитория, поэтому корень берём от самого файла.
# AWG_REPO_ROOT позволяет проверить другую копию дерева, ничего не правя.
ROOT = os.environ.get("AWG_REPO_ROOT") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))

P = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(ROOT, "bot", "awg_bot.py")
src = io.open(P, encoding="utf-8").read()
PER = int(re.search(r"^CLIENTS_PER_PAGE = (\d+)", src, re.M).group(1))
fail = 0


def chk(label, cond, extra=""):
    global fail
    print(("  ✔ " if cond else "  ✘ ") + label + ("" if cond else "  " + extra))
    if not cond:
        fail = 1


def paginate(total, page):
    """Тот же расчёт, что в обработчике бота."""
    pages = max(1, (total + PER - 1) // PER)
    page = min(max(0, page), pages - 1)
    chunk = list(range(total))[page * PER:(page + 1) * PER]
    return pages, page, chunk, (page - 1) % pages, (page + 1) % pages


print("── Размер страницы ─────────────────────────────────────────────────────")
chk("CLIENTS_PER_PAGE = 10", PER == 10, "получено %d" % PER)

print()
print("── 87 клиентов (как на боевом сервере) ─────────────────────────────────")
pages, page, chunk, pv, nx = paginate(87, 0)
chk("страниц 9", pages == 9, str(pages))
chk("на первой 10 записей", len(chunk) == 10)
chk("назад с первой уводит на последнюю", pv == 8, str(pv))
pages, page, chunk, pv, nx = paginate(87, 8)
chk("на последней 7 записей", len(chunk) == 7, str(len(chunk)))
chk("вперёд с последней уводит на первую", nx == 0, str(nx))
seen = sum(len(paginate(87, p)[2]) for p in range(9))
chk("суммарно показаны все 87, ничего не потеряно", seen == 87, str(seen))

print()
print("── Границы ─────────────────────────────────────────────────────────────")
chk("0 клиентов → 1 страница", paginate(0, 0)[0] == 1)
chk("10 клиентов → 1 страница", paginate(10, 0)[0] == 1)
chk("11 клиентов → 2 страницы", paginate(11, 0)[0] == 2)
chk("страница за пределом прижимается к последней", paginate(87, 999)[1] == 8)
chk("отрицательная прижимается к первой", paginate(87, -5)[1] == 0)

print()
print("── Код в боте ──────────────────────────────────────────────────────────")
chk("обработчик принимает и clients:list, и clients:list:N",
    'd == "clients:list" or d.startswith("clients:list:")' in src)
chk("мусор в номере страницы не роняет обработчик", "except ValueError" in src)
chk("жёсткого среза [:80] в коде нет", "(az + vp + van + ov)[:80]" not in src)
chk("в тексте сказано, сколько всего клиентов", "Всего {len(allc)}" in src)
chk("навигация рисуется только при нескольких страницах", "if pages > 1:" in src)

print()
print("═══ ВСЁ ЗЕЛЁНОЕ ═══" if not fail else "═══ ЕСТЬ ПАДЕНИЯ ═══")
sys.exit(fail)
