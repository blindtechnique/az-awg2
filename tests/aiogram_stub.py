# -*- coding: utf-8 -*-
"""Заглушка aiogram: ровно та поверхность, которую трогает awg_bot.py.

Настоящий aiogram в тестовой среде не нужен — проверяем логику бота, а не
библиотеку. Заглушка регистрируется в sys.modules ДО импорта awg_bot.
"""
import sys
import types


class _Any:
    """F.data и подобное: любой доступ и любая операция возвращают то же самое."""
    def __getattr__(self, _):
        return self
    def __call__(self, *a, **k):
        return self
    def __eq__(self, _):
        return self
    def __hash__(self):
        return 0


class Bot:
    def __init__(self, token, *a, **k):
        self.token = token
        self.sent = []
    async def send_message(self, chat, text, **k):
        self.sent.append((chat, text))
    async def send_document(self, *a, **k):
        pass
    async def set_my_commands(self, *a, **k):
        pass


class Dispatcher:
    def __init__(self, *a, **k):
        self.handlers = []
    def _reg(self, *a, **k):
        def deco(fn):
            self.handlers.append(fn)
            return fn
        return deco
    message = callback_query = _reg
    async def start_polling(self, *a, **k):
        pass


class State:
    def __init__(self, *a, **k):
        pass


class StatesGroup:
    pass


class MemoryStorage:
    pass


class FSMContext:
    pass


class TelegramBadRequest(Exception):
    def __init__(self, *a, **k):
        super().__init__("stub")


class InlineKeyboardButton:
    def __init__(self, text="", callback_data=""):
        self.text, self.callback_data = text, callback_data


class InlineKeyboardMarkup:
    def __init__(self, inline_keyboard=None):
        self.inline_keyboard = inline_keyboard or []


class Message:
    pass


class CallbackQuery:
    pass


class FSInputFile:
    def __init__(self, *a, **k):
        pass


class BotCommand:
    def __init__(self, *a, **k):
        pass


def install():
    root = types.ModuleType("aiogram")
    root.Bot, root.Dispatcher, root.F = Bot, Dispatcher, _Any()
    mods = {
        "aiogram": root,
        "aiogram.filters": dict(Command=lambda *a, **k: _Any()),
        "aiogram.fsm": {},
        "aiogram.fsm.context": dict(FSMContext=FSMContext),
        "aiogram.fsm.state": dict(State=State, StatesGroup=StatesGroup),
        "aiogram.fsm.storage": {},
        "aiogram.fsm.storage.memory": dict(MemoryStorage=MemoryStorage),
        "aiogram.exceptions": dict(TelegramBadRequest=TelegramBadRequest),
        "aiogram.types": dict(Message=Message, FSInputFile=FSInputFile,
                              CallbackQuery=CallbackQuery, BotCommand=BotCommand,
                              InlineKeyboardMarkup=InlineKeyboardMarkup,
                              InlineKeyboardButton=InlineKeyboardButton),
    }
    for name, attrs in mods.items():
        m = root if name == "aiogram" else types.ModuleType(name)
        if isinstance(attrs, dict):
            for k, v in attrs.items():
                setattr(m, k, v)
        sys.modules[name] = m
    return root
