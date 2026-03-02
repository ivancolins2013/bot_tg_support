import os
import sys
import asyncio
import logging
import socket
from logging.handlers import RotatingFileHandler

from aiogram import Bot, Dispatcher
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import BotCommand, BotCommandScopeDefault, BotCommandScopeChat

from config import load_settings
from db import init_db_pool, close_db_pool
from handlers import get_routers

# Гарантируем, что можно запускать bot.py из любой директории
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

LOGGER = logging.getLogger("support_bot")


def resolve_log_file_path() -> str:
    raw = os.getenv("BOT_LOG_FILE", os.path.join("logs", "bot.log"))
    if os.path.isabs(raw):
        return raw
    return os.path.join(BASE_DIR, raw)


def translate_aiogram_dispatcher_message(message: str) -> str:
    if message == "Start polling":
        return "📡 Запуск polling"
    if message == "Polling stopped":
        return "🛑 Polling остановлен"
    if message.startswith("Run polling for bot "):
        details = message.removeprefix("Run polling for bot ")
        return f"🤖 Polling запущен для бота {details}"
    if message.startswith("Polling stopped for bot "):
        details = message.removeprefix("Polling stopped for bot ")
        return f"🛑 Polling остановлен для бота {details}"
    return message


class AiogramDispatcherRuFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        if record.name.startswith("aiogram.dispatcher"):
            translated = translate_aiogram_dispatcher_message(record.getMessage())
            if translated != record.getMessage():
                record.msg = translated
                record.args = ()
        return True


def configure_logging():
    log_file_path = resolve_log_file_path()
    log_dir = os.path.dirname(log_file_path)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)

    formatter = logging.Formatter(
        fmt="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)

    file_handler = RotatingFileHandler(
        filename=log_file_path,
        maxBytes=5 * 1024 * 1024,
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.INFO)
    root_logger.handlers.clear()
    root_logger.addHandler(console_handler)
    root_logger.addHandler(file_handler)

    # Keep third-party framework logs mostly quiet, but show dispatcher info in Russian.
    logging.getLogger("aiogram").setLevel(logging.WARNING)
    dispatcher_logger = logging.getLogger("aiogram.dispatcher")
    dispatcher_logger.setLevel(logging.INFO)
    for flt in list(dispatcher_logger.filters):
        if isinstance(flt, AiogramDispatcherRuFilter):
            dispatcher_logger.removeFilter(flt)
    dispatcher_logger.addFilter(AiogramDispatcherRuFilter())
    logging.getLogger("aiohttp").setLevel(logging.WARNING)
    LOGGER.info("📝 Логи пишутся в файл: %s", log_file_path)


class SingleInstanceLock:
    """Process lock to prevent running multiple bot.py instances."""

    def __init__(self, lock_name: str):
        self.lock_name = lock_name
        self.sock: socket.socket | None = None
        # Stable port in [46000..46999] based on project path/name.
        self.port = 46000 + (zlib_crc32(lock_name) % 1000)

    def acquire(self) -> bool:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            self.sock.bind(("127.0.0.1", self.port))
            self.sock.listen(1)
        except OSError:
            self.sock.close()
            self.sock = None
            return False
        return True

    def release(self):
        if self.sock is None:
            return
        self.sock.close()
        self.sock = None


def zlib_crc32(value: str) -> int:
    import zlib  # pylint: disable=import-outside-toplevel

    return zlib.crc32(value.encode("utf-8")) & 0xFFFFFFFF


async def setup_bot_commands(bot: Bot, admin_chat_id: int):
    """
    Настраиваем команды:
    - для всех (в ЛС и в обычных чатах)
    - отдельно для админ-чата (панель и служебные команды)
    """

    # Команды по умолчанию (для пользователей, ЛС и т.п.)
    user_commands = [
        BotCommand(command="start", description="Запуск бота"),
        BotCommand(command="help", description="Помощь по боту"),
        BotCommand(command="profile", description="Мой профиль"),
        BotCommand(command="setnick", description="Указать ник на сервере"),
        BotCommand(command="ticket", description="История тикета по ID"),
    ]
    await bot.set_my_commands(
        commands=user_commands,
        scope=BotCommandScopeDefault(),  # по умолчанию для всех чатов
    )

    # Команды только для админ-беседы
    admin_commands = [
        BotCommand(command="panel", description="Панель управления тикетами"),
        BotCommand(command="tickets", description="Открытые тикеты"),
        BotCommand(command="stats", description="Статистика тикетов"),
        BotCommand(command="close", description="Закрыть тикет по ID"),
        BotCommand(command="userinfo", description="Профиль автора тикета"),
        BotCommand(command="adminhelp", description="Справка по админ-командам"),
    ]
    await bot.set_my_commands(
        commands=admin_commands,
        scope=BotCommandScopeChat(chat_id=admin_chat_id),
    )


async def main():
    LOGGER.info("🚀 Запуск бота начат")

    settings = load_settings()
    if not settings.bot_token or not settings.admin_chat_id:
        raise RuntimeError("Не заданы BOT_TOKEN или ADMIN_CHAT_ID в .env")
    LOGGER.info("⚙️ Настройки загружены (admin_chat_id=%s)", settings.admin_chat_id)

    # Инициализируем пул БД
    LOGGER.info("🗄️ Инициализация пула БД")
    await init_db_pool(settings)
    LOGGER.info("✅ Пул БД готов")

    bot = Bot(token=settings.bot_token)
    dp = Dispatcher(storage=MemoryStorage())
    LOGGER.info("🤖 Aiogram Bot и Dispatcher инициализированы")

    # Кладём settings в контекст Dispatcher,
    # чтобы их можно было получать в хендлерах через параметр settings: Settings
    dp["settings"] = settings

    # Регистрируем команды бота (отдельно для юзеров и для админ-чата)
    LOGGER.info("🧭 Настраиваю команды бота")
    await setup_bot_commands(bot, settings.admin_chat_id)
    LOGGER.info("✅ Команды бота настроены")

    # Подключаем роутеры
    routers = get_routers()
    for router in routers:
        dp.include_router(router)
    LOGGER.info("🧩 Подключено роутеров: %s", len(routers))

    try:
        LOGGER.info("📡 Polling запущен. Для остановки нажми Ctrl+C.")
        await dp.start_polling(bot)
        LOGGER.info("🛑 Polling остановлен")
    finally:
        LOGGER.info("🧹 Завершение: закрываю ресурсы")
        await close_db_pool()
        LOGGER.info("🗄️ Пул БД закрыт")
        await bot.session.close()
        LOGGER.info("🔌 Сессия бота закрыта")


if __name__ == "__main__":
    configure_logging()
    LOGGER.info("🚀 Инициализация процесса бота")

    instance_lock = SingleInstanceLock(BASE_DIR)
    if not instance_lock.acquire():
        LOGGER.error(
            "❌ Уже запущен другой экземпляр бота. Останови его перед новым запуском."
        )
        raise SystemExit(1)
    LOGGER.info("🔒 Single-instance lock получен на 127.0.0.1:%s", instance_lock.port)

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        LOGGER.info("👋 Бот остановлен пользователем")
    except Exception:
        LOGGER.exception("💥 Бот остановлен из-за необработанного исключения")
        raise
    finally:
        instance_lock.release()
        LOGGER.info("🔓 Single-instance lock освобожден")
