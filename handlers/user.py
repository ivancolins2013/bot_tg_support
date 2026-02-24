from aiogram import Router, F, Bot
from aiogram.filters import CommandStart, Command, StateFilter
from aiogram.types import (
    Message,
    ReplyKeyboardMarkup,
    KeyboardButton,
    InlineKeyboardMarkup,
    InlineKeyboardButton,
    InputMediaPhoto,
)
from aiogram.fsm.state import StatesGroup, State
from aiogram.fsm.context import FSMContext

import asyncio
import logging
import time  # ← если ещё нет
from config import Settings
from db import (
    create_ticket,
    set_ticket_thread,
    get_user_tickets,
    get_user_last_active_ticket,
    add_ticket_message,
    get_ticket_with_messages,
    get_user_active_tickets,
    get_user_active_tickets_count,
    get_user_profile,
    upsert_user_profile,
)

CATEGORY_BUTTONS = [
    ("💳 Донат", "donate"),
    ("🛠 Баг / тех. проблема", "bug"),
    # ("⚖️ Жалоба на игрока/персонал", "complaint"),
    # ("❓ Вопрос по игре", "question"),
    ("📦 Другое", "other"),
]

CATEGORY_TITLES = {
    "donate": "💳 Донат",
    "bug": "🛠 Баг / тех. проблема",
    # "complaint": "⚖️ Жалоба",
    # "question": "❓ Вопрос",
    "other": "📦 Другое",
}

MAX_ACTIVE_TICKETS_PER_USER = 1

# Антиспам по пользователям
USER_COOLDOWNS: dict[int, float] = {}
COOLDOWN_SECONDS = 5  # можно поставить 3, 10, 30 — как удобнее

PHOTO_ALBUM_FLUSH_DELAY = 4.0
USER_PHOTO_ALBUMS: dict[tuple[int, str], dict] = {}
USER_PHOTO_ALBUM_IGNORED: set[tuple[int, str]] = set()
NEW_TICKET_PHOTO_ALBUMS: dict[tuple[int, str], dict] = {}
USER_PHOTO_ALBUM_LOCKS: dict[tuple[int, str], asyncio.Lock] = {}
NEW_TICKET_PHOTO_ALBUM_LOCKS: dict[tuple[int, str], asyncio.Lock] = {}

user_router = Router()
LOGGER = logging.getLogger("support_bot.user")


class NewTicket(StatesGroup):
    waiting_for_category = State()
    waiting_for_topic = State()
    waiting_for_text = State()


class ProfileEdit(StatesGroup):
    waiting_for_nickname = State()


def category_keyboard() -> ReplyKeyboardMarkup:
    rows = [[KeyboardButton(text=btn_text)] for (btn_text, _) in CATEGORY_BUTTONS]
    return ReplyKeyboardMarkup(
        keyboard=rows,
        resize_keyboard=True,
        one_time_keyboard=True,
    )


def main_keyboard() -> ReplyKeyboardMarkup:
    kb = [
        [KeyboardButton(text="📩 Создать тикет")],
        [KeyboardButton(text="📜 Мои тикеты")],
        [KeyboardButton(text="👤 Профиль")],
    ]
    return ReplyKeyboardMarkup(
        keyboard=kb,
        resize_keyboard=True,
    )


def is_on_cooldown(user_id: int) -> bool:
    """
    Проверяем, не слишком ли часто пишет пользователь.
    True  -> пользователь ещё на кулдауне
    False -> можно писать, кулдаун обновлён
    """
    now = time.time()
    last = USER_COOLDOWNS.get(user_id, 0)

    if now - last < COOLDOWN_SECONDS:
        return True

    USER_COOLDOWNS[user_id] = now
    return False


def normalize_nickname(raw: str) -> str:
    return " ".join((raw or "").strip().split())


def is_valid_nickname(nickname: str) -> bool:
    return 3 <= len(nickname) <= 24


def get_album_lock(
    lock_map: dict[tuple[int, str], asyncio.Lock],
    key: tuple[int, str],
) -> asyncio.Lock:
    lock = lock_map.get(key)
    if lock is None:
        lock = asyncio.Lock()
        lock_map[key] = lock
    return lock


def truncate_caption(text: str, limit: int = 1024) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def build_ticket_admin_keyboard(ticket_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(
                    text="🛠 Взять в работу",
                    callback_data=f"take_ticket:{ticket_id}",
                ),
                InlineKeyboardButton(
                    text="✔ Закрыть тикет",
                    callback_data=f"close_ticket:{ticket_id}",
                ),
            ]
        ]
    )


async def create_and_publish_new_ticket(
    *,
    bot: Bot,
    settings: Settings,
    user_id: int,
    username: str | None,
    topic: str,
    text: str,
    category: str,
    game_nickname: str,
    photo_ids: list[str] | None = None,
) -> tuple[int, str]:
    ticket_id = await create_ticket(
        user_id=user_id,
        username=username,
        topic=topic,
        text=text,
        category=category,
    )

    cat_title = CATEGORY_TITLES.get(category, "📦 Другое")
    topic_name = f"[{cat_title}] #{ticket_id}: {topic[:30]}"
    forum_topic = await bot.create_forum_topic(
        chat_id=settings.admin_chat_id,
        name=topic_name,
    )
    thread_id = forum_topic.message_thread_id
    await set_ticket_thread(ticket_id, thread_id)

    username_str = f"@{username}" if username else "Р±РµР· username"
    kb = build_ticket_admin_keyboard(ticket_id)

    if photo_ids:
        caption = truncate_caption(
            (
                f"🆕 Новый тикет #{ticket_id}\n"
                f"Никнейм на сервере: {game_nickname}\n"
                f"Категория: {cat_title}\n"
                f"РћС‚: {username_str} (ID: {user_id})\n"
                f"Тема: {topic}\n\n"
                f"{text}"
            )
        )
        send_kwargs = {
            "chat_id": settings.admin_chat_id,
            "message_thread_id": thread_id,
        }

        for idx in range(0, len(photo_ids), 10):
            chunk = photo_ids[idx : idx + 10]
            media_group: list[InputMediaPhoto] = []
            for chunk_idx, file_id in enumerate(chunk):
                if idx == 0 and chunk_idx == 0 and caption:
                    media_group.append(InputMediaPhoto(media=file_id, caption=caption))
                else:
                    media_group.append(InputMediaPhoto(media=file_id))
            await bot.send_media_group(media=media_group, **send_kwargs)

        await bot.send_message(
            chat_id=settings.admin_chat_id,
            message_thread_id=thread_id,
            text="Р’СЃРµ РѕС‚РІРµС‚С‹ РїРѕ СЌС‚РѕРјСѓ С‚РёРєРµС‚Сѓ РїРёС€РёС‚Рµ РІ СЌС‚РѕР№ С‚РµРјРµ.",
            reply_markup=kb,
        )
    else:
        admin_text = (
            f"🆕 Новый тикет #{ticket_id}\n"
            f"Никнейм на сервере: {game_nickname}\n"
            f"Категория: {cat_title}\n"
            f"РћС‚: {username_str} (ID: {user_id})\n"
            f"Тема: {topic}\n\n"
            f"{text}\n\n"
            f"Р’СЃРµ РѕС‚РІРµС‚С‹ РїРѕ СЌС‚РѕРјСѓ С‚РёРєРµС‚Сѓ РїРёС€РёС‚Рµ РІ СЌС‚РѕР№ С‚РµРјРµ."
        )
        await bot.send_message(
            chat_id=settings.admin_chat_id,
            message_thread_id=thread_id,
            text=admin_text,
            reply_markup=kb,
        )

    LOGGER.info(
        "📨 Новый тикет #%s отправлен в админ-чат (user_id=%s, thread_id=%s, photos=%s)",
        ticket_id,
        user_id,
        thread_id,
        len(photo_ids or []),
    )

    return ticket_id, cat_title


async def flush_new_ticket_photo_album(
    key: tuple[int, str],
    *,
    bot: Bot,
    settings: Settings,
):
    lock = get_album_lock(NEW_TICKET_PHOTO_ALBUM_LOCKS, key)
    while True:
        async with lock:
            payload = NEW_TICKET_PHOTO_ALBUMS.get(key)
            if payload is None:
                NEW_TICKET_PHOTO_ALBUM_LOCKS.pop(key, None)
                return

            sleep_for = PHOTO_ALBUM_FLUSH_DELAY - (
                time.monotonic() - payload["last_update"]
            )
        if sleep_for <= 0:
            break
        await asyncio.sleep(sleep_for)

    async with lock:
        payload = NEW_TICKET_PHOTO_ALBUMS.pop(key, None)
        NEW_TICKET_PHOTO_ALBUM_LOCKS.pop(key, None)
    if not payload:
        return

    user_id = payload["user_id"]
    topic = payload["topic"]
    category = payload["category"]
    photos: list[str] = payload["photos"]
    caption_text = payload["caption"] or f"[Альбом фото от игрока: {len(photos)} шт.]"
    chat_id = payload["chat_id"]
    username = payload["username"]
    state: FSMContext = payload["state"]

    profile = await get_user_profile(user_id)
    game_nickname = profile["game_nickname"] if profile else "РЅРµ СѓРєР°Р·Р°РЅ"

    await state.clear()

    try:
        ticket_id, cat_title = await create_and_publish_new_ticket(
            bot=bot,
            settings=settings,
            user_id=user_id,
            username=username,
            topic=topic,
            text=caption_text,
            category=category,
            game_nickname=game_nickname,
            photo_ids=photos,
        )
        await bot.send_message(
            chat_id=chat_id,
            text=(
                f"✅ Тикет #{ticket_id} создан!\n"
                f"Категория: {cat_title}\n"
                f"Мы получили альбом ({len(photos)} фото). "
                "Администраторы ответят, как только рассмотрят обращение."
            ),
            reply_markup=main_keyboard(),
        )
        LOGGER.info(
            "✅ Тикет #%s создан из альбома пользователя (user_id=%s, photos=%s)",
            ticket_id,
            user_id,
            len(photos),
        )
    except Exception as exc:
        LOGGER.exception(
            "❌ Не удалось создать тикет из альбома (user_id=%s, photos=%s)",
            user_id,
            len(photos),
        )
        await bot.send_message(
            chat_id=chat_id,
            text=f"⚠ Не удалось создать тикет из альбома: {exc!r}",
            reply_markup=main_keyboard(),
        )


async def handle_new_ticket_photo_album_message(
    message: Message,
    state: FSMContext,
    bot: Bot,
    settings: Settings,
) -> bool:
    user = message.from_user
    media_group_id = message.media_group_id
    if user is None or not media_group_id or not message.photo:
        return False

    key = (user.id, media_group_id)
    lock = get_album_lock(NEW_TICKET_PHOTO_ALBUM_LOCKS, key)
    async with lock:
        payload = NEW_TICKET_PHOTO_ALBUMS.get(key)
        if payload is None:
            data = await state.get_data()
            payload = {
                "user_id": user.id,
                "username": user.username if user else None,
                "topic": data.get("topic", "Р‘РµР· С‚РµРјС‹"),
                "category": data.get("category", "other"),
                "chat_id": message.chat.id,
                "photos": [],
                "caption": "",
                "last_update": time.monotonic(),
                "state": state,
            }
            NEW_TICKET_PHOTO_ALBUMS[key] = payload
            asyncio.create_task(
                flush_new_ticket_photo_album(
                    key,
                    bot=bot,
                    settings=settings,
                )
            )

        payload["photos"].append(message.photo[-1].file_id)
        payload["last_update"] = time.monotonic()
        caption_text = (message.caption or "").strip()
        if caption_text and not payload["caption"]:
            payload["caption"] = caption_text

    return True


async def flush_user_photo_album(
    key: tuple[int, str],
    *,
    bot: Bot,
    settings: Settings,
):
    lock = get_album_lock(USER_PHOTO_ALBUM_LOCKS, key)
    while True:
        async with lock:
            payload = USER_PHOTO_ALBUMS.get(key)
            if payload is None:
                USER_PHOTO_ALBUM_IGNORED.discard(key)
                USER_PHOTO_ALBUM_LOCKS.pop(key, None)
                return

            sleep_for = PHOTO_ALBUM_FLUSH_DELAY - (
                time.monotonic() - payload["last_update"]
            )
        if sleep_for <= 0:
            break
        await asyncio.sleep(sleep_for)

    async with lock:
        payload = USER_PHOTO_ALBUMS.pop(key, None)
        USER_PHOTO_ALBUM_IGNORED.discard(key)
        USER_PHOTO_ALBUM_LOCKS.pop(key, None)
    if not payload:
        return

    photos: list[str] = payload["photos"]
    if not photos:
        return

    ticket_id = payload["ticket_id"]
    thread_id = payload["thread_id"]
    user_chat_id = payload["user_chat_id"]
    caption_text = payload["caption"]
    base_text = caption_text or f"[Альбом фото от игрока: {len(photos)} шт.]"
    admin_caption = caption_text or None

    send_kwargs = {"chat_id": settings.admin_chat_id}
    if thread_id:
        send_kwargs["message_thread_id"] = thread_id

    try:
        for idx in range(0, len(photos), 10):
            chunk = photos[idx : idx + 10]
            media_group: list[InputMediaPhoto] = []
            for chunk_idx, file_id in enumerate(chunk):
                if idx == 0 and chunk_idx == 0:
                    if admin_caption:
                        media_group.append(
                            InputMediaPhoto(media=file_id, caption=admin_caption[:1024])
                        )
                    else:
                        media_group.append(InputMediaPhoto(media=file_id))
                else:
                    media_group.append(InputMediaPhoto(media=file_id))

            await bot.send_media_group(media=media_group, **send_kwargs)

        await add_ticket_message(ticket_id, "user", base_text)
        await bot.send_message(
            chat_id=user_chat_id,
            text=(
                f"Твой альбом ({len(photos)} фото) добавлен в тикет #{ticket_id}. "
                "Ожидай ответа администрации."
            ),
            reply_markup=main_keyboard(),
        )
        LOGGER.info(
            "📤 Альбом пользователя отправлен в тикет #%s (photos=%s)",
            ticket_id,
            len(photos),
        )
    except Exception as exc:
        LOGGER.exception(
            "❌ Не удалось отправить альбом пользователя (ticket_id=%s, photos=%s)",
            ticket_id,
            len(photos),
        )
        await bot.send_message(
            chat_id=user_chat_id,
            text=f"⚠ Не удалось отправить альбом в тикет: {exc!r}",
            reply_markup=main_keyboard(),
        )


async def handle_user_photo_album_message(
    message: Message,
    bot: Bot,
    settings: Settings,
) -> bool:
    user = message.from_user
    media_group_id = message.media_group_id
    if user is None or not media_group_id or not message.photo:
        return False

    key = (user.id, media_group_id)
    if key in USER_PHOTO_ALBUM_IGNORED:
        return True

    lock = get_album_lock(USER_PHOTO_ALBUM_LOCKS, key)
    async with lock:
        payload = USER_PHOTO_ALBUMS.get(key)
        if payload is None:
            ticket = await get_user_last_active_ticket(user.id)
            if not ticket:
                USER_PHOTO_ALBUM_IGNORED.add(key)
                await message.answer(
                    "У тебя сейчас нет активных тикетов.\n"
                    "Нажми «📩 Создать тикет», чтобы открыть новый.",
                    reply_markup=main_keyboard(),
                )
                return True

            payload = {
                "ticket_id": ticket["id"],
                "thread_id": ticket.get("admin_thread_id"),
                "user_chat_id": message.chat.id,
                "photos": [],
                "caption": "",
                "last_update": time.monotonic(),
            }
            USER_PHOTO_ALBUMS[key] = payload
            asyncio.create_task(
                flush_user_photo_album(
                    key,
                    bot=bot,
                    settings=settings,
                )
            )

        payload["photos"].append(message.photo[-1].file_id)
        payload["last_update"] = time.monotonic()
        caption_text = (message.caption or "").strip()
        if caption_text and not payload["caption"]:
            payload["caption"] = caption_text

    return True


async def prompt_ticket_category(message: Message, state: FSMContext):
    await state.set_state(NewTicket.waiting_for_category)
    await message.answer(
        "Выбери категорию обращения:",
        reply_markup=category_keyboard(),
    )


async def ensure_profile_or_prompt(message: Message, state: FSMContext) -> bool:
    profile = await get_user_profile(message.from_user.id)
    if profile:
        return True

    await state.set_state(ProfileEdit.waiting_for_nickname)
    await state.update_data(profile_next_action="start_ticket")
    await message.answer(
        "Сначала регистрация профиля.\n"
        "Введи никнейм, который используешь на сервере (3-24 символа).",
        reply_markup=ReplyKeyboardMarkup(
            keyboard=[[KeyboardButton(text="РћС‚РјРµРЅР°")]],
            resize_keyboard=True,
            one_time_keyboard=True,
        ),
    )
    return False


async def handle_nickname_input(message: Message, state: FSMContext):
    text = (message.text or "").strip()
    if text.lower() == "РѕС‚РјРµРЅР°":
        await state.clear()
        await message.answer("РћРє, РѕС‚РјРµРЅРµРЅРѕ.", reply_markup=main_keyboard())
        return

    nickname = normalize_nickname(text)
    if not is_valid_nickname(nickname):
        await message.answer(
            "Никнейм должен быть от 3 до 24 символов. Попробуй еще раз.",
            reply_markup=ReplyKeyboardMarkup(
                keyboard=[[KeyboardButton(text="РћС‚РјРµРЅР°")]],
                resize_keyboard=True,
                one_time_keyboard=True,
            ),
        )
        return

    await upsert_user_profile(message.from_user.id, nickname)
    data = await state.get_data()
    next_action = data.get("profile_next_action")
    await state.clear()

    if next_action == "start_ticket":
        await message.answer(
            f"Профиль сохранен. Твой ник: {nickname}",
            reply_markup=main_keyboard(),
        )
        await prompt_ticket_category(message, state)
        return

    await message.answer(
        f"Профиль обновлен. Твой ник: {nickname}",
        reply_markup=main_keyboard(),
    )


@user_router.message(CommandStart(), F.chat.type == "private")
async def cmd_start(message: Message, state: FSMContext):
    """
    Старт бота для игрока.
    Показываем приветствие и основное меню.
    """
    await state.clear()

    text = (
        "Привет! Я бот поддержки проекта VEGA.\n\n"
        "Через меня ты можешь:\n"
        "• 📩 создать тикет и описать свою проблему;\n"
        "• 📜 посмотреть список своих тикетов и их статус;\n"
        "• получать ответы от администрации прямо здесь в ЛС.\n\n"
        "Нажми «📩 Создать тикет», чтобы открыть обращение."
    )

    await message.answer(text, reply_markup=main_keyboard())


@user_router.message(Command("profile"), F.chat.type == "private")
async def cmd_profile(message: Message):
    profile = await get_user_profile(message.from_user.id)
    if not profile:
        await message.answer(
            "Профиль еще не создан.\n"
            "Напиши /setnick и укажи никнейм на сервере.",
            reply_markup=main_keyboard(),
        )
        return

    await message.answer(
        f"Твой профиль:\n"
        f"Никнейм на сервере: {profile['game_nickname']}\n\n"
        f"Изменить ник: /setnick",
        reply_markup=main_keyboard(),
    )


@user_router.message(Command("setnick"), F.chat.type == "private")
async def cmd_setnick(message: Message, state: FSMContext):
    await state.set_state(ProfileEdit.waiting_for_nickname)
    await state.update_data(profile_next_action=None)
    await message.answer(
        "Введи никнейм на сервере (3-24 символа).",
        reply_markup=ReplyKeyboardMarkup(
            keyboard=[[KeyboardButton(text="РћС‚РјРµРЅР°")]],
            resize_keyboard=True,
            one_time_keyboard=True,
        ),
    )


@user_router.message(ProfileEdit.waiting_for_nickname, F.chat.type == "private")
async def profile_nickname_received(message: Message, state: FSMContext):
    await handle_nickname_input(message, state)


@user_router.message(Command("help"), F.chat.type == "private")
async def cmd_help(message: Message):
    """
    Подсказка по командам для игрока.
    """
    text = (
        "🆘 Помощь по боту поддержки\n\n"
        "Доступные действия:\n"
        "• /start — перезапустить бота и показать меню;\n"
        "• /help — показать это сообщение;\n"
        "• /profile — показать сохраненный никнейм;\n"
        "• /setnick — изменить никнейм на сервере;\n"
        "• Кнопка «📩 Создать тикет» — открыть новое обращение;\n"
        "• Кнопка «📜 Мои тикеты» — список твоих тикетов и их статусы.\n\n"
        "После создания тикета:\n"
        "• Ты пишешь сообщения сюда, в этот чат;\n"
        "• Бот передаёт их администрации в отдельную тему;\n"
        "• Ответы администрации будут приходить тебе сюда.\n\n"
        "⏳ Не спамь, между сообщениями есть небольшой кулдаун."
    )

    await message.answer(text, reply_markup=main_keyboard())


@user_router.message(Command("newticket"), F.chat.type == "private")
async def cmd_new_ticket(message: Message, state: FSMContext):
    if not await ensure_profile_or_prompt(message, state):
        return

    # проверяем, сколько уже активных тикетов
    active_count = await get_user_active_tickets_count(message.from_user.id)

    if active_count >= MAX_ACTIVE_TICKETS_PER_USER:
        active_rows = await get_user_active_tickets(message.from_user.id)
        lines = [
            "⚠ У тебя уже есть активный тикет.\n"
            "Сначала дождись ответа или закрытия текущего тикета.\n\n"
            "Твои активные тикеты:\n"
        ]

        for row in active_rows:
            status_map = {
                "open": "🟢 Открыт",
                "in_work": "🟡 В работе",
            }
            status = status_map.get(row["status"], row["status"])
            cat_title = CATEGORY_TITLES.get(row.get("category", "other"), "📦 Другое")

            lines.append(
                f"#{row['id']} — {status}\n"
                f"Категория: {cat_title}\n"
                f"Тема: {row['topic']}\n\n"
            )

        await message.answer("".join(lines), reply_markup=main_keyboard())
        return

    # если лимит не превышен — идём по обычному сценарию
    await prompt_ticket_category(message, state)


@user_router.message(NewTicket.waiting_for_category, F.chat.type == "private")
async def ticket_category_received(message: Message, state: FSMContext):
    text = (message.text or "").strip()

    # РёС‰РµРј СЃРѕРІРїР°РґРµРЅРёРµ РїРѕ РЅР°Р·РІР°РЅРёСЋ РєРЅРѕРїРєРё
    category_code = "other"
    for btn_text, code in CATEGORY_BUTTONS:
        if text == btn_text:
            category_code = code
            break

    await state.update_data(category=category_code)
    await state.set_state(NewTicket.waiting_for_topic)

    await message.answer(
        "Укажи кратко тему обращения (например: «Проблема с донатом»).",
        reply_markup=ReplyKeyboardMarkup(
            keyboard=[[KeyboardButton(text="РћС‚РјРµРЅР°")]],
            resize_keyboard=True,
            one_time_keyboard=True,
        ),
    )


@user_router.message(NewTicket.waiting_for_topic, F.chat.type == "private")
async def ticket_topic_received(message: Message, state: FSMContext):
    await state.update_data(topic=message.text.strip())
    await state.set_state(NewTicket.waiting_for_text)
    await message.answer("Теперь подробно опиши свою проблему одним сообщением.")


@user_router.message(NewTicket.waiting_for_text, F.chat.type == "private")
async def ticket_text_received(
    message: Message,
    state: FSMContext,
    bot: Bot,
    settings: Settings,
):
    if await handle_new_ticket_photo_album_message(message, state, bot, settings):
        return

    if any(album_key[0] == message.from_user.id for album_key in NEW_TICKET_PHOTO_ALBUMS):
        await message.answer(
            "⏳ Получаю альбом, подожди пару секунд и не отправляй дополнительные сообщения.",
            reply_markup=main_keyboard(),
        )
        return

    if is_on_cooldown(message.from_user.id):
        await message.answer(
            f"⏳ Не спамь, можно отправлять сообщения раз в {COOLDOWN_SECONDS} секунд.",
            reply_markup=main_keyboard(),
        )
        return

    data = await state.get_data()
    topic = data.get("topic", "Р‘РµР· С‚РµРјС‹")
    category = data.get("category", "other")

    text = (message.text or message.caption or "").strip()
    photo_ids: list[str] | None = None
    if message.photo:
        photo_ids = [message.photo[-1].file_id]
        if not text:
            text = "[Фото от игрока]"

    if not text:
        await message.answer(
            "Пустое сообщение я не могу приложить к новому тикету.",
            reply_markup=main_keyboard(),
        )
        return

    await state.clear()

    username = message.from_user.username if message.from_user else None
    profile = await get_user_profile(message.from_user.id)
    game_nickname = profile["game_nickname"] if profile else "РЅРµ СѓРєР°Р·Р°РЅ"

    ticket_id, cat_title = await create_and_publish_new_ticket(
        bot=bot,
        settings=settings,
        user_id=message.from_user.id,
        username=username,
        topic=topic,
        text=text,
        category=category,
        game_nickname=game_nickname,
        photo_ids=photo_ids,
    )

    await message.answer(
        f"✅ Тикет #{ticket_id} создан!\n"
        f"Категория: {cat_title}\n"
        f"Наши администраторы ответят тебе, как только рассмотрят обращение.",
        reply_markup=main_keyboard(),
    )
    LOGGER.info(
        "✅ Новый тикет #%s создан пользователем %s (photos=%s)",
        ticket_id,
        message.from_user.id,
        1 if photo_ids else 0,
    )


@user_router.message(Command("ticket"), F.chat.type == "private")
async def user_show_ticket(message: Message):
    """Пользователь смотрит историю своего тикета: /ticket ID"""
    parts = message.text.split()
    if len(parts) < 2:
        await message.reply(
            "Использование: /ticket ID\nНапример: /ticket 4",
            reply_markup=main_keyboard(),
        )
        return

    try:
        ticket_id = int(parts[1])
    except ValueError:
        await message.reply(
            "ID тикета должен быть числом.", reply_markup=main_keyboard()
        )
        return

    data = await get_ticket_with_messages(ticket_id)
    if not data:
        await message.reply("Тикет с таким ID не найден.", reply_markup=main_keyboard())
        return

    ticket = data["ticket"]
    messages = data["messages"]

    # проверяем, что тикет принадлежит этому пользователю
    if ticket["user_id"] != message.from_user.id:
        await message.reply(
            "У тебя нет доступа к этому тикету.", reply_markup=main_keyboard()
        )
        return

    status_map = {
        "open": "🟢 Открыт",
        "in_work": "🟡 В работе",
        "closed": "⚪ Закрыт",
    }
    status = status_map.get(ticket["status"], ticket["status"])
    cat_title = CATEGORY_TITLES.get(ticket.get("category", "other"), "📦 Другое")

    header = (
        f"📄 Тикет #{ticket['id']} — {status}\n"
        f"Категория: {cat_title}\n"
        f"Тема: {ticket['topic']}\n"
        f"Создан: {ticket['created_at']}\n\n"
        f"История сообщений:\n"
    )

    lines = [header]

    if not messages:
        lines.append("Пока нет сообщений.")
    else:
        for msg in messages:
            who = "Ты" if msg["sender"] == "user" else "Администрация"
            created = msg["created_at"]
            text = msg["text"]
            lines.append(f"\n{who} [{created}]:\n{text}\n")

    full_text = "".join(lines)
    if len(full_text) > 4000:
        full_text = full_text[:4000] + "\n\n…обрезано, слишком длинная история."

    await message.reply(full_text, reply_markup=main_keyboard())


@user_router.message(Command("mytickets"), F.chat.type == "private")
async def show_my_tickets(message: Message):
    rows = await get_user_tickets(message.from_user.id)
    if not rows:
        await message.answer("У тебя пока нет тикетов.", reply_markup=main_keyboard())
        return

    lines = ["Твои последние тикеты:\n\n"]
    status_map = {
        "open": "🟢 Открыт",
        "in_work": "🟡 В работе",
        "closed": "⚪ Закрыт",
    }
    for row in rows:
        status = status_map.get(row["status"], row["status"])
        cat_title = CATEGORY_TITLES.get(row.get("category", "other"), "📦 Другое")
        lines.append(
            f"#{row['id']} — {status}\n"
            f"Категория: {cat_title}\n"
            f"Тема: {row['topic']}\n\n"
        )

    await message.answer("".join(lines), reply_markup=main_keyboard())


@user_router.message(StateFilter(None), F.chat.type == "private")
async def user_text_router(
    message: Message,
    state: FSMContext,
    bot: Bot,
    settings: Settings,
):
    if (message.text or "").startswith("/"):
        return

    # 1. Обработка кнопок меню
    if message.text == "📩 Создать тикет":
        await cmd_new_ticket(message, state)
        return

    if message.text == "📜 Мои тикеты":
        await show_my_tickets(message)
        return

    if message.text == "👤 Профиль":
        await cmd_profile(message)
        return

    if await handle_user_photo_album_message(message, bot, settings):
        return

    # 2. Антиспам для любых ответов в тикеты
    if is_on_cooldown(message.from_user.id):
        await message.answer(
            f"⏳ Ты слишком часто отправляешь сообщения.\n"
            f"Можно писать раз в {COOLDOWN_SECONDS} секунд.",
            reply_markup=main_keyboard(),
        )
        return

    # 3. Берём последний активный тикет
    ticket = await get_user_last_active_ticket(message.from_user.id)
    if not ticket:
        await message.answer(
            "У тебя сейчас нет активных тикетов.\n"
            "Нажми «📩 Создать тикет», чтобы открыть новый.",
            reply_markup=main_keyboard(),
        )
        return

    ticket_id = ticket["id"]
    thread_id = ticket.get("admin_thread_id")

    # --- определяем медиа ---
    has_photo = bool(message.photo)
    has_document = bool(message.document)
    has_video = bool(message.video)
    has_animation = bool(message.animation)
    has_voice = bool(message.voice)
    has_audio = bool(message.audio)
    has_sticker = bool(message.sticker)

    is_media = any(
        [
            has_photo,
            has_document,
            has_video,
            has_animation,
            has_voice,
            has_audio,
            has_sticker,
        ]
    )

    # текст — либо text, либо caption (для фото/видео/доков)
    text = (message.text or message.caption or "").strip()

    # если медиа без текста — подставляем понятное описание
    if not text and is_media:
        if has_photo:
            text = "[Фото от игрока]"
        elif has_document:
            text = f"[Документ от игрока] {message.document.file_name or ''}"
        elif has_video:
            text = "[Видео от игрока]"
        elif has_animation:
            text = "[GIF / анимация от игрока]"
        elif has_voice:
            text = "[Голосовое сообщение от игрока]"
        elif has_audio:
            text = "[Аудио от игрока]"
        elif has_sticker:
            text = "[Стикер от игрока]"
        else:
            text = "[Медиа от игрока]"

    # если вообще ни текста, ни медиа — отвечаем пользователю
    if not text and not is_media:
        await message.answer("Пустое сообщение я не могу приложить к тикету.")
        return

    # 4. Р›РѕРі РІ Р‘Р”
    await add_ticket_message(ticket_id, "user", text)

    # подпись для админ-чата
    caption = f"💬 Ответ от игрока по тикету #{ticket_id}:\n\n{text}"

    try:
        if is_media:
            # базовые параметры для отправки медиа
            send_kwargs = {
                "chat_id": settings.admin_chat_id,
                "caption": caption,
            }
            if thread_id:
                send_kwargs["message_thread_id"] = thread_id

            if has_photo:
                await bot.send_photo(
                    photo=message.photo[-1].file_id,
                    **send_kwargs,
                )
            elif has_document:
                await bot.send_document(
                    document=message.document.file_id,
                    **send_kwargs,
                )
            elif has_video:
                await bot.send_video(
                    video=message.video.file_id,
                    **send_kwargs,
                )
            elif has_animation:
                await bot.send_animation(
                    animation=message.animation.file_id,
                    **send_kwargs,
                )
            elif has_voice:
                await bot.send_voice(
                    voice=message.voice.file_id,
                    **send_kwargs,
                )
            elif has_audio:
                await bot.send_audio(
                    audio=message.audio.file_id,
                    **send_kwargs,
                )
            elif has_sticker:
                # у стикеров нет caption — отправляем стикер + отдельный текст
                sticker_kwargs = {
                    "chat_id": settings.admin_chat_id,
                    "sticker": message.sticker.file_id,
                }
                if thread_id:
                    sticker_kwargs["message_thread_id"] = thread_id

                s = await bot.send_sticker(**sticker_kwargs)

                msg_kwargs = {
                    "chat_id": settings.admin_chat_id,
                    "text": caption,
                    "reply_to_message_id": s.message_id,
                }
                if thread_id:
                    msg_kwargs["message_thread_id"] = thread_id

                await bot.send_message(**msg_kwargs)
            else:
                # на всякий случай — только текст
                msg_kwargs = {
                    "chat_id": settings.admin_chat_id,
                    "text": caption,
                }
                if thread_id:
                    msg_kwargs["message_thread_id"] = thread_id
                await bot.send_message(**msg_kwargs)
        else:
            # только текст
            msg_kwargs = {
                "chat_id": settings.admin_chat_id,
                "text": caption,
            }
            if thread_id:
                msg_kwargs["message_thread_id"] = thread_id
            await bot.send_message(**msg_kwargs)

        LOGGER.info(
            "📨 Сообщение пользователя отправлено в тикет #%s (user_id=%s, media=%s)",
            ticket_id,
            message.from_user.id,
            is_media,
        )
        await message.answer(
            f"Твоё сообщение добавлено в тикет #{ticket_id}. "
            f"Ожидай ответа от администрации.",
            reply_markup=main_keyboard(),
        )
    except Exception as exc:
        LOGGER.exception(
            "❌ Не удалось отправить сообщение пользователя в тикет #%s (user_id=%s)",
            ticket_id,
            message.from_user.id,
        )
        await message.answer(
            f"⚠ Не удалось отправить сообщение в тикет: {exc!r}",
            reply_markup=main_keyboard(),
        )
