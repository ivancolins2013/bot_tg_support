import asyncio

import logging

from aiogram import Router, F, Bot
from aiogram.filters import Command
from aiogram.types import (
    Message,
    CallbackQuery,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
    InputMediaPhoto,
)

from config import Settings
from db import (
    set_ticket_status,
    add_ticket_message,
    get_open_tickets,
    get_ticket_by_thread_id,
    get_ticket,
    get_ticket_with_messages,
    set_ticket_assignee,
    get_ticket_stats_overview,
    get_ticket_stats_by_assignee,
    get_closed_tickets_with_threads,
    get_tickets_by_status,
    get_tickets_by_assignee,
    set_ticket_thread,
    get_user_profile,
)

from handlers.user import CATEGORY_TITLES


admin_router = Router()
LOGGER = logging.getLogger("support_bot.admin")

PHOTO_ALBUM_FLUSH_DELAY = 4.0
ADMIN_PHOTO_ALBUMS: dict[tuple[int, int, str], dict] = {}
ADMIN_PHOTO_ALBUM_IGNORED: set[tuple[int, int, str]] = set()


# ==========================
#  Хелперы
# ==========================


async def get_admin_title(
    bot: Bot,
    settings: Settings,
    user_id: int,
    username: str | None,
) -> str:
    """
    Вернуть красивую должность админа:
    - custom_title из беседы (например, 'Владелец', 'Гл. админ')
    - или 'Оператор' для создателя без титула
    - или @username / id
    """
    try:
        member = await bot.get_chat_member(settings.admin_chat_id, user_id)
    except Exception:
        member = None

    title = None
    status = None

    if member is not None:
        title = getattr(member, "custom_title", None)
        status = getattr(member, "status", None)

    if title:
        return title

    if status == "creator":
        return "Оператор"

    if username:
        return f"@{username}"

    return f"admin {user_id}"


async def safe_get_admin_title(
    bot: Bot,
    settings: Settings,
    user_id: int,
    username: str | None,
) -> str:
    """Безопасно получить title админа с fallback на @username/id."""
    try:
        return await get_admin_title(bot, settings, user_id, username)
    except Exception:
        if username:
            return f"@{username}"
        return f"admin {user_id}"


def truncate_message(
    text: str,
    *,
    limit: int = 4000,
    suffix: str = "\n\n…обрезано.",
) -> str:
    """Ограничить длину текста под лимит Telegram."""
    if len(text) <= limit:
        return text
    return text[:limit] + suffix


def category_title(category: str | None) -> str:
    return CATEGORY_TITLES.get(category or "other", "📦 Другое")


def status_title(status: str) -> str:
    status_map = {
        "open": "🟢 Открыт",
        "in_work": "🟡 В работе",
        "closed": "⚪ Закрыт",
    }
    return status_map.get(status, status)


def panel_status_header(status: str) -> str:
    status_map = {
        "open": "🟢 Открытые тикеты:",
        "in_work": "🟡 Тикеты в работе:",
        "closed": "⚪ Закрытые тикеты:",
    }
    return status_map.get(status, "Тикеты:")


def assignee_title(row: dict) -> str:
    assignee = row.get("assigned_admin_username")
    if assignee:
        return f"исполнитель: @{assignee}"
    return "исполнитель: не назначен"


async def build_top_admin_lines(
    assignee_rows: list[dict],
    settings: Settings,
    bot: Bot,
) -> list[str]:
    if not assignee_rows:
        return ["\n👑 Топ админов: пока никто не взял ни одного тикета.\n"]

    lines = ["\n👑 Топ админов по тикетам:\n"]
    for row in assignee_rows:
        admin_title = await safe_get_admin_title(
            bot,
            settings,
            row["admin_id"],
            row.get("admin_username") or "",
        )
        lines.append(f"• {admin_title}: {row['tickets_count']} тикетов\n")
    return lines


async def build_stats_text(settings: Settings, bot: Bot) -> str:
    overview = await get_ticket_stats_overview()
    assignee_rows = await get_ticket_stats_by_assignee(limit=5)
    by_status = overview["by_status"]

    lines: list[str] = []
    lines.append("📊 Статистика по тикетам:\n")
    lines.append(f"• Всего тикетов: {overview['total']}\n")
    lines.append(f"• 🟢 Открытых: {by_status.get('open', 0)}\n")
    lines.append(f"• 🟡 В работе: {by_status.get('in_work', 0)}\n")
    lines.append(f"• ⚪ Закрытых: {by_status.get('closed', 0)}\n")
    lines.append("\n")
    lines.append(f"За последние 24 часа: {overview['last_24h']}\n")
    lines.append(f"За последние 7 дней: {overview['last_7d']}\n")
    lines.extend(await build_top_admin_lines(assignee_rows, settings, bot))

    return "".join(lines)


def format_status_rows(status: str, rows: list[dict]) -> str:
    lines = [panel_status_header(status) + "\n\n"]
    for row in rows:
        cat = category_title(row.get("category"))
        assignee = assignee_title(row)
        lines.append(
            f"#{row['id']} — {row['topic']} "
            f"[{cat}] "
            f"(user_id: {row['user_id']}, status: {row['status']}, {assignee})\n"
        )
    return truncate_message("".join(lines))


def format_my_rows(admin_title: str, rows: list[dict]) -> str:
    lines = [f"👤 Тикеты в работе у {admin_title}:\n\n"]
    for row in rows:
        cat = category_title(row.get("category"))
        lines.append(
            f"#{row['id']} — {row['topic']} "
            f"[{cat}] "
            f"(status: {row['status']}, user_id: {row['user_id']})\n"
        )
    return truncate_message("".join(lines))


def parse_callback_ticket_id(data: str | None, prefix: str) -> int | None:
    raw = data or ""
    if not raw.startswith(prefix):
        return None
    try:
        return int(raw.split(":", 1)[1])
    except (ValueError, IndexError):
        return None


def build_close_ticket_markup(ticket_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(
                    text="✔ Закрыть тикет",
                    callback_data=f"close_ticket:{ticket_id}",
                )
            ]
        ]
    )


def parse_ticket_id_from_command(text: str | None) -> int | None:
    parts = (text or "").split()
    if len(parts) < 2:
        return None
    try:
        return int(parts[1])
    except ValueError:
        return None


def format_optional(value: object | None) -> str:
    if value is None:
        return "не указано"
    if isinstance(value, str) and not value.strip():
        return "не указано"
    return str(value)


def format_bool(value: bool | None) -> str:
    if value is True:
        return "да"
    if value is False:
        return "нет"
    return "неизвестно"


async def resolve_ticket_for_admin_command(
    message: Message,
    command_name: str,
) -> dict | None:
    ticket_id = parse_ticket_id_from_command(message.text)
    if ticket_id is not None:
        ticket = await get_ticket(ticket_id)
        if ticket is None:
            await message.reply("Тикет с таким ID не найден.")
            return None
        return ticket

    parts = (message.text or "").split()
    if len(parts) >= 2:
        await message.reply("ID тикета должен быть числом.")
        return None

    thread_id = message.message_thread_id
    if not thread_id:
        await message.reply(
            f"Использование: {command_name} ID\n"
            f"Или отправь {command_name} внутри темы тикета."
        )
        return None

    ticket = await get_ticket_by_thread_id(thread_id)
    if ticket is None:
        await message.reply("Для этой темы тикет не найден.")
        return None

    full_ticket = await get_ticket(ticket["id"])
    return full_ticket or ticket


async def build_ticket_user_info_text(
    ticket: dict,
    bot: Bot,
) -> str:
    ticket_id = ticket["id"]
    user_id = ticket["user_id"]
    db_username = ticket.get("username")
    profile = await get_user_profile(user_id)
    game_nickname = profile["game_nickname"] if profile else None

    lines = [
        f"👤 Профиль автора тикета #{ticket_id}",
        f"Telegram ID: {user_id}",
        f"Username в БД: @{db_username}" if db_username else "Username в БД: не указан",
        f"Ник на сервере: {format_optional(game_nickname)}",
        f"Ссылка (tg://): tg://user?id={user_id}",
    ]
    if db_username:
        lines.append(f"Публичная ссылка: https://t.me/{db_username}")

    try:
        chat = await bot.get_chat(user_id)
    except Exception as exc:
        lines.append("")
        lines.append(
            "⚠️ Не удалось получить актуальные данные из Telegram API: "
            f"{type(exc).__name__}"
        )
        return truncate_message("\n".join(lines))

    tg_username = getattr(chat, "username", None)
    first_name = getattr(chat, "first_name", None)
    last_name = getattr(chat, "last_name", None)
    full_name = getattr(chat, "full_name", None)
    if not full_name:
        full_name = " ".join(part for part in (first_name, last_name) if part) or None
    bio = getattr(chat, "bio", None)
    has_private_forwards = getattr(chat, "has_private_forwards", None)

    language_code = None
    is_premium = None
    is_bot = None
    try:
        member = await bot.get_chat_member(chat_id=user_id, user_id=user_id)
        member_user = getattr(member, "user", None)
        if member_user is not None:
            language_code = getattr(member_user, "language_code", None)
            is_premium = getattr(member_user, "is_premium", None)
            is_bot = getattr(member_user, "is_bot", None)
    except Exception:
        pass

    lines.extend(
        [
            "",
            "Актуальные данные Telegram:",
            f"Тип чата: {format_optional(getattr(chat, 'type', None))}",
            (
                f"Username Telegram: @{tg_username}"
                if tg_username
                else "Username Telegram: не указан"
            ),
            f"Имя: {format_optional(first_name)}",
            f"Фамилия: {format_optional(last_name)}",
            f"Полное имя: {format_optional(full_name)}",
            f"Язык клиента: {format_optional(language_code)}",
            f"Premium: {format_bool(is_premium)}",
            f"Это бот: {format_bool(is_bot)}",
            f"Скрытые пересылки: {format_bool(has_private_forwards)}",
            f"Bio: {format_optional(bio)}",
            (
                f"Ссылка (public): https://t.me/{tg_username}"
                if tg_username
                else f"Ссылка (private): tg://user?id={user_id}"
            ),
        ]
    )

    return truncate_message("\n".join(lines))


def format_ticket_history(ticket: dict, messages: list[dict]) -> str:
    username = ticket.get("username") or "без username"
    category = category_title(ticket.get("category"))
    status = status_title(ticket["status"])

    assignee_username = ticket.get("assigned_admin_username")
    if assignee_username:
        assignee = f"Исполнитель: @{assignee_username}"
    else:
        assignee = "Исполнитель: не назначен"

    header = (
        f"📄 Тикет #{ticket['id']} — {status}\n"
        f"Категория: {category}\n"
        f"От: @{username} (user_id: {ticket['user_id']})\n"
        f"{assignee}\n"
        f"Тема: {ticket['topic']}\n"
        f"Создан: {ticket['created_at']}\n\n"
        f"История сообщений:\n"
    )

    lines = [header]
    if not messages:
        lines.append("Пока нет сообщений.")
    else:
        for msg in messages:
            who = "👤 Игрок" if msg["sender"] == "user" else "🛡 Админ"
            lines.append(f"\n{who} [{msg['created_at']}]:\n{msg['text']}\n")

    return truncate_message(
        "".join(lines),
        suffix="\n\n…обрезано, слишком длинная история.",
    )


# ==========================
#  Команды для админов
# ==========================


@admin_router.message(Command("adminhelp"))
async def admin_help(message: Message, settings: Settings):
    """
    Подсказка по командам для админов.
    """
    if message.chat.id != settings.admin_chat_id:
        await message.answer("Эта команда доступна только в админском чате.")
        return

    text = (
        "🛡 Справка по админ-функциям бота\n\n"
        "Команды в админ-чате:\n"
        "• /panel — панель управления тикетами (кнопки: "
        "открытые / в работе / закрытые / мои / статистика / архив);\n"
        "• /tickets — список всех открытых и «в работе» тикетов;\n"
        "• /stats — общая статистика по тикетам;\n"
        "• /close <ID> — закрыть тикет по ID;\n"
        "• /ticket <ID> — вывести историю конкретного тикета;\n"
        "• /userinfo <ID> — показать Telegram-профиль автора тикета;\n"
        "• /adminhelp — эта справка.\n\n"
        "Работа с темами тикетов:\n"
        "• При создании тикета бот создаёт тему в этом чате;\n"
        "• В сообщении о новом тикете есть кнопка «Взять тикет в работу» — "
        "назначает исполнителя и ставит статус «в работе»;\n"
        "• Всё, что вы пишете в теме (текст + медиа), бот отправляет игроку в ЛС;\n"
        "• Кнопка «Закрыть тикет» закрывает тикет и тему, игрок получает уведомление.\n\n"
        "Архивация:\n"
        "• Кнопка «🧹 Архивировать закрытые» в /panel удаляет темы закрытых тикетов "
        "и очищает привязку в БД."
    )

    await message.answer(text)


@admin_router.message(Command("help"))
async def admin_help_alias(message: Message, settings: Settings):
    """
    В админ-чате /help показывает админскую справку,
    в других местах — игнорируется (в ЛС обрабатывается user.py).
    """
    if message.chat.id != settings.admin_chat_id:
        return
    await admin_help(message, settings)


@admin_router.message(Command("close"))
async def admin_close_ticket(message: Message, settings: Settings, bot: Bot):
    """Закрытие тикета по команде /close ID + закрытие темы."""
    if message.chat.id != settings.admin_chat_id:
        return

    parts = message.text.split()
    if len(parts) < 2:
        await message.reply("Использование: /close ID")
        return

    try:
        ticket_id = int(parts[1])
    except ValueError:
        await message.reply("ID тикета должен быть числом.")
        return

    ticket = await get_ticket(ticket_id)
    if not ticket:
        await message.reply("Тикет с таким ID не найден.")
        return

    if ticket["status"] == "closed":
        await message.reply("Этот тикет уже закрыт.")
        return

    user_id = ticket["user_id"]
    thread_id = ticket["admin_thread_id"]

    await set_ticket_status(ticket_id, "closed")
    await add_ticket_message(
        ticket_id, "admin", f"[Тикет закрыт админом {message.from_user.id}]"
    )

    try:
        await bot.send_message(
            chat_id=user_id,
            text=(
                f"✅ Твой тикет #{ticket_id} был закрыт администрацией.\n"
                f"Если проблема не решена — создай новый тикет."
            ),
        )
        LOGGER.info(
            "📤 Пользователь %s уведомлен о закрытии тикета #%s",
            user_id,
            ticket_id,
        )
    except Exception:
        LOGGER.exception(
            "❌ Не удалось уведомить пользователя о закрытии тикета #%s (user_id=%s)",
            ticket_id,
            user_id,
        )

    if thread_id:
        try:
            await bot.close_forum_topic(
                chat_id=settings.admin_chat_id,
                message_thread_id=thread_id,
            )
            LOGGER.info("🧵 Тема тикета #%s закрыта (thread_id=%s)", ticket_id, thread_id)
        except Exception:
            LOGGER.exception(
                "❌ Не удалось закрыть тему тикета #%s (thread_id=%s)",
                ticket_id,
                thread_id,
            )

        try:
            await bot.send_message(
                chat_id=settings.admin_chat_id,
                message_thread_id=thread_id,
                text="🔒 Тикет закрыт, тема закрыта.",
            )
            LOGGER.info(
                "📣 В тему тикета #%s отправлено сообщение о закрытии",
                ticket_id,
            )
        except Exception:
            LOGGER.exception(
                "❌ Не удалось отправить сообщение о закрытии в тему тикета #%s",
                ticket_id,
            )

    await message.reply(f"Тикет #{ticket_id} закрыт.")


@admin_router.message(Command("tickets"))
async def admin_list_open_tickets(message: Message, settings: Settings):
    """Список открытых и 'в работе' тикетов."""
    if message.chat.id != settings.admin_chat_id:
        return

    rows = await get_open_tickets()
    if not rows:
        await message.answer("Нет открытых тикетов.")
        return

    lines = ["Открытые/в работе тикеты:\n\n"]
    for row in rows:
        cat_title = CATEGORY_TITLES.get(row.get("category", "other"), "📦 Другое")
        thread_info = (
            f"(thread_id: {row['admin_thread_id']})"
            if row["admin_thread_id"]
            else "(без темы)"
        )
        assignee = row.get("assigned_admin_username")
        if assignee:
            assignee_str = f"исполнитель: @{assignee}"
        else:
            assignee_str = "исполнитель: не назначен"

        lines.append(
            f"#{row['id']} — {row['topic']} "
            f"[{cat_title}] "
            f"(user_id: {row['user_id']}, status: {row['status']}, {assignee_str}) {thread_info}\n"
        )

    await message.answer("".join(lines))

@admin_router.message(Command("panel"))
async def admin_panel(message: Message, settings: Settings):
    """Панель управления тикетами: /panel."""
    if message.chat.id != settings.admin_chat_id:
        return

    kb = InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(
                    text="🟢 Открытые",
                    callback_data="panel:open",
                ),
                InlineKeyboardButton(
                    text="🟡 В работе",
                    callback_data="panel:in_work",
                ),
            ],
            [
                InlineKeyboardButton(
                    text="⚪ Закрытые",
                    callback_data="panel:closed",
                ),
                InlineKeyboardButton(
                    text="👤 Мои тикеты",
                    callback_data="panel:my",
                ),
            ],
            [
                InlineKeyboardButton(
                    text="📊 Статистика",
                    callback_data="panel:stats",
                ),
                InlineKeyboardButton(
                    text="🧹 Архивировать закрытые",
                    callback_data="panel:archive",
                ),
            ],
        ]
    )

    await message.answer("Панель управления тикетами:", reply_markup=kb)


@admin_router.message(Command("stats"))
async def admin_stats(
    message: Message,
    settings: Settings,
    bot: Bot,
):
    """Статистика по тикетам: /stats."""
    if message.chat.id != settings.admin_chat_id:
        return

    await message.answer(await build_stats_text(settings, bot))


@admin_router.message(Command("ticket"))
async def admin_show_ticket(
    message: Message,
    settings: Settings,
):
    """Показ истории тикета по ID для админов: /ticket 4"""
    if message.chat.id != settings.admin_chat_id:
        return

    ticket_id = parse_ticket_id_from_command(message.text)
    if ticket_id is None:
        if len((message.text or "").split()) < 2:
            await message.reply("Использование: /ticket ID")
            return
        await message.reply("ID тикета должен быть числом.")
        return

    data = await get_ticket_with_messages(ticket_id)
    if not data:
        await message.reply("Тикет с таким ID не найден.")
        return

    await message.reply(format_ticket_history(data["ticket"], data["messages"]))


@admin_router.message(Command("userinfo"))
@admin_router.message(Command("user"))
async def admin_show_ticket_user_info(
    message: Message,
    settings: Settings,
    bot: Bot,
):
    """
    Полная информация по Telegram-аккаунту автора тикета.
    Использование:
    - /userinfo ID
    - /userinfo внутри темы тикета
    """
    if message.chat.id != settings.admin_chat_id:
        return

    ticket = await resolve_ticket_for_admin_command(message, "/userinfo")
    if ticket is None:
        return

    await message.reply(await build_ticket_user_info_text(ticket, bot))


# ==========================
#  Callback: закрытие тикета
# ==========================


@admin_router.callback_query(F.data.startswith("close_ticket:"))
async def close_ticket_callback(
    callback: CallbackQuery,
    settings: Settings,
    bot: Bot,
):
    """Обработка нажатия инлайн-кнопки 'Закрыть тикет'."""
    if callback.message is None:
        return

    if callback.message.chat.id != settings.admin_chat_id:
        await callback.answer("Не тот чат.", show_alert=True)
        return

    data = callback.data or ""
    try:
        _, ticket_id_str = data.split(":", 1)
        ticket_id = int(ticket_id_str)
    except (ValueError, IndexError):
        await callback.answer("Некорректный ID тикета.", show_alert=True)
        return

    ticket = await get_ticket(ticket_id)
    if not ticket:
        await callback.answer("Тикет не найден.", show_alert=True)
        return

    if ticket["status"] == "closed":
        await callback.answer("Этот тикет уже закрыт.", show_alert=False)
        return

    user_id = ticket["user_id"]
    thread_id = ticket["admin_thread_id"]

    await set_ticket_status(ticket_id, "closed")
    await add_ticket_message(
        ticket_id, "admin", f"[Тикет закрыт через кнопку #{callback.from_user.id}]"
    )

    try:
        await bot.send_message(
            chat_id=user_id,
            text=(
                f"✅ Твой тикет #{ticket_id} был закрыт администрацией.\n"
                f"Если проблема не решена — создай новый тикет."
            ),
        )
        LOGGER.info(
            "📤 Пользователь %s уведомлен о закрытии тикета #%s",
            user_id,
            ticket_id,
        )
    except Exception:
        LOGGER.exception(
            "❌ Не удалось уведомить пользователя о закрытии тикета #%s (user_id=%s)",
            ticket_id,
            user_id,
        )

    if thread_id:
        try:
            await bot.close_forum_topic(
                chat_id=settings.admin_chat_id,
                message_thread_id=thread_id,
            )
            LOGGER.info("🧵 Тема тикета #%s закрыта (thread_id=%s)", ticket_id, thread_id)
        except Exception:
            LOGGER.exception(
                "❌ Не удалось закрыть тему тикета #%s (thread_id=%s)",
                ticket_id,
                thread_id,
            )

        try:
            await bot.send_message(
                chat_id=settings.admin_chat_id,
                message_thread_id=thread_id,
                text="🔒 Тикет закрыт, тема закрыта.",
            )
            LOGGER.info(
                "📣 В тему тикета #%s отправлено сообщение о закрытии",
                ticket_id,
            )
        except Exception:
            LOGGER.exception(
                "❌ Не удалось отправить сообщение о закрытии в тему тикета #%s",
                ticket_id,
            )

    try:
        old_text = callback.message.text or ""
        if "🔒 Тикет закрыт." not in old_text:
            new_text = old_text + "\n\n🔒 Тикет закрыт."
            await callback.message.edit_text(new_text, reply_markup=None)
        else:
            await callback.message.edit_reply_markup(reply_markup=None)
    except Exception:
        pass

    await callback.answer("Тикет закрыт.", show_alert=False)


# ==========================
#  Callback: взять тикет в работу
# ==========================


@admin_router.callback_query(F.data.startswith("take_ticket:"))
async def take_ticket_callback(
    callback: CallbackQuery,
    settings: Settings,
    bot: Bot,
):
    """Обработка нажатия инлайн-кнопки 'Взять тикет в работу'."""
    if callback.message is None:
        return

    if callback.message.chat.id != settings.admin_chat_id:
        await callback.answer("Не тот чат.", show_alert=True)
        return

    ticket_id = parse_callback_ticket_id(callback.data, "take_ticket:")
    if ticket_id is None:
        await callback.answer("Некорректный ID тикета.", show_alert=True)
        return

    ticket = await get_ticket(ticket_id)
    if not ticket:
        await callback.answer("Тикет не найден.", show_alert=True)
        return

    if ticket["status"] == "closed":
        await callback.answer("Тикет уже закрыт.", show_alert=False)
        return

    admin_id = callback.from_user.id
    admin_username = callback.from_user.username or ""
    admin_title = await safe_get_admin_title(
        bot,
        settings,
        admin_id,
        admin_username,
    )

    if ticket.get("assigned_admin_id") and ticket["assigned_admin_id"] != admin_id:
        current_admin = (
            ticket.get("assigned_admin_username") or ticket["assigned_admin_id"]
        )
        await callback.answer(
            f"Тикет уже в работе у @{current_admin}.",
            show_alert=True,
        )
        return

    await set_ticket_status(ticket_id, "in_work")
    await set_ticket_assignee(ticket_id, admin_id, admin_username)
    await add_ticket_message(
        ticket_id,
        "admin",
        f"[Тикет взят в работу админом {admin_title}]",
    )

    try:
        await bot.send_message(
            chat_id=settings.admin_chat_id,
            message_thread_id=ticket["admin_thread_id"],
            text=f"🛠 Тикет #{ticket_id} взят в работу админом: {admin_title}.",
        )
        LOGGER.info(
            "📣 Отправлено сообщение в тему о взятии тикета #%s в работу",
            ticket_id,
        )
    except Exception:
        LOGGER.exception(
            "❌ Не удалось отправить сообщение в тему о взятии тикета #%s",
            ticket_id,
        )

    try:
        await bot.send_message(
            chat_id=ticket["user_id"],
            text=(
                f"🛠 Твой тикет #{ticket_id} взят в работу.\n"
                f"Ответственный: {admin_title}.\n"
                f"Ожидай ответа от администрации."
            ),
        )
        LOGGER.info(
            "📤 Пользователь %s уведомлен о взятии тикета #%s в работу",
            ticket["user_id"],
            ticket_id,
        )
    except Exception:
        LOGGER.exception(
            "❌ Не удалось уведомить пользователя о взятии тикета #%s в работу",
            ticket_id,
        )

    try:
        old_text = callback.message.text or ""
        mark_line = f"\n\n🛠 В работе: {admin_title}"
        new_text = old_text if "🛠 В работе:" in old_text else old_text + mark_line

        await callback.message.edit_text(
            new_text,
            reply_markup=build_close_ticket_markup(ticket_id),
        )
    except Exception:
        pass

    await callback.answer("Ты взял тикет в работу.", show_alert=False)


# ==========================
#  Callback: панель /panel
# ==========================


async def handle_panel_status_action(callback: CallbackQuery, status: str):
    if callback.message is None:
        return

    rows = await get_tickets_by_status(status, limit=20)
    if not rows:
        await callback.message.answer("Нет тикетов с таким статусом.")
        return

    await callback.message.answer(format_status_rows(status, rows))


async def handle_panel_my_action(
    callback: CallbackQuery,
    settings: Settings,
    bot: Bot,
):
    if callback.message is None:
        return

    admin_id = callback.from_user.id
    admin_username = callback.from_user.username or ""
    admin_title = await safe_get_admin_title(
        bot,
        settings,
        admin_id,
        admin_username,
    )

    rows = await get_tickets_by_assignee(admin_id, limit=20)
    if not rows:
        await callback.message.answer(f"У {admin_title} пока нет тикетов в работе.")
        return

    await callback.message.answer(format_my_rows(admin_title, rows))


async def handle_panel_stats_action(
    callback: CallbackQuery,
    settings: Settings,
    bot: Bot,
):
    if callback.message is None:
        return
    await callback.message.answer(await build_stats_text(settings, bot))


async def handle_panel_archive_action(
    callback: CallbackQuery,
    settings: Settings,
    bot: Bot,
):
    if callback.message is None:
        return

    rows = await get_closed_tickets_with_threads()
    if not rows:
        await callback.message.answer(
            "Нет закрытых тикетов с темами для архивации."
        )
        return

    total = len(rows)
    success = 0
    failed = 0

    for row in rows:
        thread_id = row["admin_thread_id"]
        ticket_id = row["id"]

        try:
            await bot.delete_forum_topic(
                chat_id=settings.admin_chat_id,
                message_thread_id=thread_id,
            )
            success += 1
        except Exception:
            failed += 1
            LOGGER.exception(
                "❌ Не удалось удалить тему закрытого тикета #%s (thread_id=%s)",
                ticket_id,
                thread_id,
            )
        finally:
            await set_ticket_thread(ticket_id, None)

    text = (
        f"🧹 Архивация закрытых тикетов завершена.\n"
        f"Всего найдено тем: {total}\n"
        f"Успешно удалено: {success}\n"
        f"Ошибок при удалении: {failed}"
    )
    await callback.message.answer(text)


@admin_router.callback_query(F.data.startswith("panel:"))
async def admin_panel_callback(
    callback: CallbackQuery,
    settings: Settings,
    bot: Bot,
):
    """Обработка кнопок панели /panel."""
    if callback.message is None:
        return

    if callback.message.chat.id != settings.admin_chat_id:
        await callback.answer("Не тот чат.", show_alert=True)
        return

    action_data = callback.data or ""
    action = action_data.split(":", 1)[1] if ":" in action_data else ""

    if action in ("open", "in_work", "closed"):
        await handle_panel_status_action(callback, action)
        await callback.answer()
        return

    action_handlers = {
        "my": handle_panel_my_action,
        "stats": handle_panel_stats_action,
        "archive": handle_panel_archive_action,
    }
    handler = action_handlers.get(action)
    if handler is not None:
        await handler(callback, settings, bot)

    await callback.answer()


# ==========================
#  Сообщения в темах тикетов
# ==========================


def detect_media_type(message: Message) -> str | None:
    checks = (
        ("photo", bool(message.photo)),
        ("document", bool(message.document)),
        ("video", bool(message.video)),
        ("animation", bool(message.animation)),
        ("voice", bool(message.voice)),
        ("audio", bool(message.audio)),
        ("sticker", bool(message.sticker)),
    )
    for media_type, has_media in checks:
        if has_media:
            return media_type
    return None


def default_admin_media_text(message: Message, media_type: str) -> str:
    if media_type == "document":
        return f"[Документ от администрации] {message.document.file_name or ''}"
    text_map = {
        "photo": "[Фото от администрации]",
        "video": "[Видео от администрации]",
        "animation": "[GIF / анимация от администрации]",
        "voice": "[Голосовое сообщение от администрации]",
        "audio": "[Аудио от администрации]",
        "sticker": "[Стикер от администрации]",
    }
    return text_map.get(media_type, "[Медиа от администрации]")


async def flush_admin_photo_album(
    key: tuple[int, int, str],
    *,
    bot: Bot,
    settings: Settings,
):
    loop = asyncio.get_running_loop()
    while True:
        payload = ADMIN_PHOTO_ALBUMS.get(key)
        if payload is None:
            ADMIN_PHOTO_ALBUM_IGNORED.discard(key)
            return

        sleep_for = PHOTO_ALBUM_FLUSH_DELAY - (loop.time() - payload["last_update"])
        if sleep_for <= 0:
            break
        await asyncio.sleep(sleep_for)

    payload = ADMIN_PHOTO_ALBUMS.pop(key, None)
    ADMIN_PHOTO_ALBUM_IGNORED.discard(key)
    if not payload:
        return

    photos: list[str] = payload["photos"]
    if not photos:
        return

    ticket_id = payload["ticket_id"]
    thread_id = payload["thread_id"]
    user_id = payload["user_id"]
    ticket_was_open = payload["ticket_was_open"]
    caption_text = payload["caption"]
    base_text = caption_text or f"[Альбом фото от администрации: {len(photos)} шт.]"
    user_caption = caption_text or None

    try:
        if ticket_was_open:
            await set_ticket_status(ticket_id, "in_work")

        for idx in range(0, len(photos), 10):
            chunk = photos[idx : idx + 10]
            media_group: list[InputMediaPhoto] = []
            for chunk_idx, file_id in enumerate(chunk):
                if idx == 0 and chunk_idx == 0:
                    if user_caption:
                        media_group.append(
                            InputMediaPhoto(media=file_id, caption=user_caption[:1024])
                        )
                    else:
                        media_group.append(InputMediaPhoto(media=file_id))
                else:
                    media_group.append(InputMediaPhoto(media=file_id))
            await bot.send_media_group(chat_id=user_id, media=media_group)

        await add_ticket_message(ticket_id, "admin", base_text)
        await bot.send_message(
            chat_id=settings.admin_chat_id,
            message_thread_id=thread_id,
            text=f"Ответ (альбом из {len(photos)} фото) отправлен пользователю.",
        )
        LOGGER.info(
            "📤 Альбом администратора отправлен пользователю (ticket_id=%s, user_id=%s, photos=%s)",
            ticket_id,
            user_id,
            len(photos),
        )
    except Exception as exc:
        LOGGER.exception(
            "❌ Не удалось отправить альбом администратора пользователю "
            "(ticket_id=%s, user_id=%s, photos=%s)",
            ticket_id,
            user_id,
            len(photos),
        )
        await bot.send_message(
            chat_id=settings.admin_chat_id,
            message_thread_id=thread_id,
            text=(
                "Не удалось отправить альбом пользователю: "
                f"{exc!r}"
            ),
        )


async def handle_admin_photo_album_message(
    message: Message,
    ticket: dict,
    bot: Bot,
    settings: Settings,
) -> bool:
    media_group_id = message.media_group_id
    thread_id = message.message_thread_id
    if not media_group_id or not thread_id or not message.photo:
        return False

    key = (message.chat.id, thread_id, media_group_id)
    if key in ADMIN_PHOTO_ALBUM_IGNORED:
        return True

    payload = ADMIN_PHOTO_ALBUMS.get(key)
    if payload is None:
        payload = {
            "ticket_id": ticket["id"],
            "user_id": ticket["user_id"],
            "thread_id": thread_id,
            "ticket_was_open": ticket["status"] == "open",
            "photos": [],
            "caption": "",
            "last_update": asyncio.get_running_loop().time(),
        }
        ADMIN_PHOTO_ALBUMS[key] = payload
        asyncio.create_task(
            flush_admin_photo_album(
                key,
                bot=bot,
                settings=settings,
            )
        )

    payload["photos"].append(message.photo[-1].file_id)
    payload["last_update"] = asyncio.get_running_loop().time()
    caption_text = (message.caption or "").strip()
    if caption_text and not payload["caption"]:
        payload["caption"] = caption_text

    return True


async def send_admin_reply_to_user(
    *,
    bot: Bot,
    message: Message,
    user_id: int,
    caption: str,
    media_type: str | None,
):
    if media_type == "photo":
        await bot.send_photo(
            chat_id=user_id,
            photo=message.photo[-1].file_id,
            caption=caption,
        )
    elif media_type == "document":
        await bot.send_document(
            chat_id=user_id,
            document=message.document.file_id,
            caption=caption,
        )
    elif media_type == "video":
        await bot.send_video(
            chat_id=user_id,
            video=message.video.file_id,
            caption=caption,
        )
    elif media_type == "animation":
        await bot.send_animation(
            chat_id=user_id,
            animation=message.animation.file_id,
            caption=caption,
        )
    elif media_type == "voice":
        await bot.send_voice(
            chat_id=user_id,
            voice=message.voice.file_id,
            caption=caption,
        )
    elif media_type == "audio":
        await bot.send_audio(
            chat_id=user_id,
            audio=message.audio.file_id,
            caption=caption,
        )
    elif media_type == "sticker":
        sticker_msg = await bot.send_sticker(
            chat_id=user_id,
            sticker=message.sticker.file_id,
        )
        await bot.send_message(
            chat_id=user_id,
            text=caption,
            reply_to_message_id=sticker_msg.message_id,
        )
    else:
        await bot.send_message(
            chat_id=user_id,
            text=caption,
        )


@admin_router.message(
    F.chat.type.in_({"supergroup", "group"}),
    ~F.text.startswith("/"),
)
async def admin_thread_message(
    message: Message,
    bot: Bot,
    settings: Settings,
):
    """Любое сообщение админа внутри темы тикета."""
    if message.chat.id != settings.admin_chat_id:
        return

    thread_id = message.message_thread_id
    if not thread_id:
        return

    ticket = await get_ticket_by_thread_id(thread_id)
    if not ticket:
        return

    ticket_id = ticket["id"]
    user_id = ticket["user_id"]

    if await handle_admin_photo_album_message(message, ticket, bot, settings):
        return

    media_type = detect_media_type(message)
    text = (message.text or message.caption or "").strip()

    if not text and media_type:
        text = default_admin_media_text(message, media_type)

    if not text:
        return

    if ticket["status"] == "open":
        await set_ticket_status(ticket_id, "in_work")

    await add_ticket_message(ticket_id, "admin", text)

    caption = f"✉ Ответ по твоему тикету #{ticket_id}:\n\n{text}"

    try:
        await send_admin_reply_to_user(
            bot=bot,
            message=message,
            user_id=user_id,
            caption=caption,
            media_type=media_type,
        )

        LOGGER.info(
            "📨 Ответ администратора отправлен пользователю (ticket_id=%s, user_id=%s, media_type=%s)",
            ticket_id,
            user_id,
            media_type or "text",
        )
        await message.reply("Ответ отправлен пользователю.")
    except Exception as exc:
        LOGGER.exception(
            "❌ Не удалось отправить ответ администратора пользователю "
            "(ticket_id=%s, user_id=%s)",
            ticket_id,
            user_id,
        )
        await message.reply(f"Не удалось отправить сообщение пользователю: {exc!r}")
