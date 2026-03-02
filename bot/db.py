from typing import Any, Dict, List, Optional

import aiomysql

from config import Settings

POOL: aiomysql.Pool | None = None


async def ensure_schema():
    """Create required tables if they are missing."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute("SHOW TABLES LIKE %s", ("tickets",))
            tickets_exists = await cur.fetchone() is not None
            if not tickets_exists:
                await cur.execute(
                    """
                    CREATE TABLE tickets (
                        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
                        user_id BIGINT NOT NULL,
                        username VARCHAR(64) NULL,
                        category VARCHAR(32) NOT NULL DEFAULT 'other',
                        topic VARCHAR(255) NOT NULL,
                        status ENUM('open', 'in_work', 'closed') NOT NULL
                            DEFAULT 'open',
                        admin_thread_id BIGINT NULL,
                        assigned_admin_id BIGINT NULL,
                        assigned_admin_username VARCHAR(64) NULL,
                        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,
                        PRIMARY KEY (id),
                        KEY idx_tickets_user_id (user_id),
                        KEY idx_tickets_status (status),
                        KEY idx_tickets_thread (admin_thread_id),
                        KEY idx_tickets_assignee (assigned_admin_id)
                    ) ENGINE=InnoDB
                    DEFAULT CHARSET=utf8mb4
                    COLLATE=utf8mb4_unicode_ci
                    """
                )

            await cur.execute("SHOW TABLES LIKE %s", ("ticket_messages",))
            ticket_messages_exists = await cur.fetchone() is not None
            if not ticket_messages_exists:
                await cur.execute(
                    """
                    CREATE TABLE ticket_messages (
                        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
                        ticket_id BIGINT UNSIGNED NOT NULL,
                        sender ENUM('user', 'admin') NOT NULL,
                        text TEXT NOT NULL,
                        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        PRIMARY KEY (id),
                        KEY idx_msg_ticket_id (ticket_id),
                        KEY idx_msg_created_at (created_at),
                        CONSTRAINT fk_ticket_messages_ticket
                            FOREIGN KEY (ticket_id) REFERENCES tickets (id)
                            ON DELETE CASCADE
                            ON UPDATE CASCADE
                    ) ENGINE=InnoDB
                    DEFAULT CHARSET=utf8mb4
                    COLLATE=utf8mb4_unicode_ci
                    """
                )

            await cur.execute("SHOW TABLES LIKE %s", ("user_profiles",))
            user_profiles_exists = await cur.fetchone() is not None
            if not user_profiles_exists:
                await cur.execute(
                    """
                    CREATE TABLE user_profiles (
                        user_id BIGINT NOT NULL,
                        game_nickname VARCHAR(64) NOT NULL,
                        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,
                        PRIMARY KEY (user_id)
                    ) ENGINE=InnoDB
                    DEFAULT CHARSET=utf8mb4
                    COLLATE=utf8mb4_unicode_ci
                    """
                )


async def init_db_pool(settings: Settings):
    global POOL
    POOL = await aiomysql.create_pool(
        host=settings.db_host,
        port=settings.db_port,
        user=settings.db_user,
        password=settings.db_password,
        db=settings.db_name,
        autocommit=True,
        minsize=1,
        maxsize=5,
    )
    await ensure_schema()


async def close_db_pool():
    global POOL
    if POOL:
        POOL.close()
        await POOL.wait_closed()
        POOL = None


async def create_ticket(
    user_id: int,
    username: Optional[str],
    topic: str,
    text: str,
    category: str,
) -> int:
    """Создаём тикет (с категорией) + первую запись."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                INSERT INTO tickets (user_id, username, category, topic, status)
                VALUES (%s, %s, %s, %s, 'open')
                """,
                (user_id, username, category, topic),
            )
            ticket_id = cur.lastrowid
            await cur.execute(
                """
                INSERT INTO ticket_messages (ticket_id, sender, text)
                VALUES (%s, 'user', %s)
                """,
                (ticket_id, text),
            )
            return ticket_id


async def set_ticket_thread(ticket_id: int, thread_id: int):
    """Привязать тикет к ID темы (message_thread_id)."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                "UPDATE tickets SET admin_thread_id = %s WHERE id = %s",
                (thread_id, ticket_id),
            )


async def add_ticket_message(ticket_id: int, sender: str, text: str):
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                INSERT INTO ticket_messages (ticket_id, sender, text)
                VALUES (%s, %s, %s)
                """,
                (ticket_id, sender, text),
            )


async def get_user_tickets(user_id: int, limit: int = 10) -> List[Dict[str, Any]]:
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT id, topic, status, category, created_at
                FROM tickets
                WHERE user_id = %s
                ORDER BY id DESC
                LIMIT %s
                """,
                (user_id, limit),
            )
            rows = await cur.fetchall()
            return rows


async def get_closed_tickets_with_threads() -> List[Dict[str, Any]]:
    """
    Все закрытые тикеты, у которых есть forum thread в админ-чате.
    Используется для архивации (удаления тем).
    """
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT id, admin_thread_id
                FROM tickets
                WHERE status = 'closed' AND admin_thread_id IS NOT NULL
                ORDER BY id DESC
                """
            )
            rows = await cur.fetchall()
            return rows


async def set_ticket_status(ticket_id: int, status: str):
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                "UPDATE tickets SET status = %s WHERE id = %s",
                (status, ticket_id),
            )


async def ticket_exists(ticket_id: int) -> bool:
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                "SELECT id FROM tickets WHERE id = %s",
                (ticket_id,),
            )
            row = await cur.fetchone()
            return row is not None


async def get_ticket_by_thread_id(thread_id: int) -> Optional[Dict[str, Any]]:
    """Получаем тикет по ID темы (message_thread_id)."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT id, user_id, username, topic, status
                FROM tickets
                WHERE admin_thread_id = %s
                """,
                (thread_id,),
            )
            row = await cur.fetchone()
            return row


async def get_open_tickets(limit: int = 20) -> List[Dict[str, Any]]:
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT
                    id,
                    user_id,
                    topic,
                    status,
                    admin_thread_id,
                    category,
                    assigned_admin_id,
                    assigned_admin_username
                FROM tickets
                WHERE status != 'closed'
                ORDER BY id DESC
                LIMIT %s
                """,
                (limit,),
            )
            rows = await cur.fetchall()
            return rows


async def get_tickets_by_status(status: str, limit: int = 20) -> List[Dict[str, Any]]:
    """
    Тикеты по статусу: open / in_work / closed.
    """
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT
                    id,
                    user_id,
                    topic,
                    status,
                    category,
                    admin_thread_id,
                    assigned_admin_id,
                    assigned_admin_username
                FROM tickets
                WHERE status = %s
                ORDER BY id DESC
                LIMIT %s
                """,
                (status, limit),
            )
            rows = await cur.fetchall()
            return rows


async def get_tickets_by_assignee(
    admin_id: int, limit: int = 20
) -> List[Dict[str, Any]]:
    """
    Активные (open + in_work) тикеты, закреплённые за конкретным админом.
    """
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT
                    id,
                    user_id,
                    topic,
                    status,
                    category,
                    admin_thread_id,
                    assigned_admin_id,
                    assigned_admin_username
                FROM tickets
                WHERE assigned_admin_id = %s
                  AND status IN ('open', 'in_work')
                ORDER BY id DESC
                LIMIT %s
                """,
                (admin_id, limit),
            )
            rows = await cur.fetchall()
            return rows


async def get_user_last_active_ticket(user_id: int) -> Optional[Dict[str, Any]]:
    """Последний тикет пользователя в статусе open / in_work."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT id, user_id, username, topic, status, admin_thread_id
                FROM tickets
                WHERE user_id = %s AND status IN ('open', 'in_work')
                ORDER BY id DESC
                LIMIT 1
                """,
                (user_id,),
            )
            row = await cur.fetchone()
            return row


async def get_ticket(ticket_id: int) -> Optional[Dict[str, Any]]:
    """Получить тикет по ID."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT
                    id,
                    user_id,
                    username,
                    topic,
                    status,
                    admin_thread_id,
                    category,
                    assigned_admin_id,
                    assigned_admin_username
                FROM tickets
                WHERE id = %s
                """,
                (ticket_id,),
            )
            row = await cur.fetchone()
            return row


async def get_ticket_with_messages(ticket_id: int) -> Optional[Dict[str, Any]]:
    """
    Получить тикет и все его сообщения.
    """
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT
                    id,
                    user_id,
                    username,
                    topic,
                    status,
                    admin_thread_id,
                    category,
                    assigned_admin_id,
                    assigned_admin_username,
                    created_at
                FROM tickets
                WHERE id = %s
                """,
                (ticket_id,),
            )
            ticket = await cur.fetchone()
            if not ticket:
                return None

            await cur.execute(
                """
                SELECT id, sender, text, created_at
                FROM ticket_messages
                WHERE ticket_id = %s
                ORDER BY id ASC
                """,
                (ticket_id,),
            )
            messages = await cur.fetchall()

            return {
                "ticket": ticket,
                "messages": messages,
            }


async def get_ticket_stats_overview() -> Dict[str, Any]:
    """
    Общая статистика по тикетам:
    - total: всего тикетов
    - by_status: словарь по статусам
    - last_24h: тикетов за последние 24 часа
    - last_7d: тикетов за последние 7 дней
    """
    assert POOL is not None
    result: Dict[str, Any] = {
        "total": 0,
        "by_status": {},
        "last_24h": 0,
        "last_7d": 0,
    }

    async with POOL.acquire() as conn:
        # всего тикетов
        async with conn.cursor() as cur:
            await cur.execute("SELECT COUNT(*) FROM tickets")
            row = await cur.fetchone()
            result["total"] = int(row[0]) if row else 0

        # по статусам
        async with conn.cursor() as cur:
            await cur.execute("SELECT status, COUNT(*) FROM tickets GROUP BY status")
            rows = await cur.fetchall()
            by_status: Dict[str, int] = {}
            for status, cnt in rows:
                by_status[status] = int(cnt)
            result["by_status"] = by_status

        # за последние 24 часа
        async with conn.cursor() as cur:
            await cur.execute(
                "SELECT COUNT(*) FROM tickets WHERE created_at >= NOW() - INTERVAL 1 DAY"
            )
            row = await cur.fetchone()
            result["last_24h"] = int(row[0]) if row else 0

        # за последние 7 дней
        async with conn.cursor() as cur:
            await cur.execute(
                "SELECT COUNT(*) FROM tickets WHERE created_at >= NOW() - INTERVAL 7 DAY"
            )
            row = await cur.fetchone()
            result["last_7d"] = int(row[0]) if row else 0

    return result


async def get_ticket_stats_by_assignee(limit: int = 5) -> List[Dict[str, Any]]:
    """
    Статистика по администраторам:
    - сколько тикетов закреплено за каждым админом
    Возвращает топ по количеству тикетов.
    """
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT
                    assigned_admin_id AS admin_id,
                    assigned_admin_username AS admin_username,
                    COUNT(*) AS tickets_count
                FROM tickets
                WHERE assigned_admin_id IS NOT NULL
                GROUP BY assigned_admin_id, assigned_admin_username
                ORDER BY tickets_count DESC
                LIMIT %s
                """,
                (limit,),
            )
            rows = await cur.fetchall()
            return rows


async def get_user_active_tickets(user_id: int) -> List[Dict[str, Any]]:
    """Все активные (open / in_work) тикеты пользователя."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT id, topic, status, category, created_at
                FROM tickets
                WHERE user_id = %s AND status IN ('open', 'in_work')
                ORDER BY id DESC
                """,
                (user_id,),
            )
            rows = await cur.fetchall()
            return rows


async def get_user_active_tickets_count(user_id: int) -> int:
    """Количество активных тикетов пользователя."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                SELECT COUNT(*)
                FROM tickets
                WHERE user_id = %s AND status IN ('open', 'in_work')
                """,
                (user_id,),
            )
            row = await cur.fetchone()
            return int(row[0]) if row else 0


async def set_ticket_assignee(
    ticket_id: int, admin_id: int, admin_username: Optional[str]
):
    """Назначить ответственного администратора за тикет."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                UPDATE tickets
                SET assigned_admin_id = %s,
                    assigned_admin_username = %s
                WHERE id = %s
                """,
                (admin_id, admin_username, ticket_id),
            )


async def get_user_profile(user_id: int) -> Optional[Dict[str, Any]]:
    """Get stored player profile by Telegram user id."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute(
                """
                SELECT user_id, game_nickname, created_at, updated_at
                FROM user_profiles
                WHERE user_id = %s
                LIMIT 1
                """,
                (user_id,),
            )
            row = await cur.fetchone()
            return row


async def upsert_user_profile(user_id: int, game_nickname: str):
    """Create or update player profile nickname."""
    assert POOL is not None
    async with POOL.acquire() as conn:
        async with conn.cursor() as cur:
            await cur.execute(
                """
                INSERT INTO user_profiles (user_id, game_nickname)
                VALUES (%s, %s)
                ON DUPLICATE KEY UPDATE
                    game_nickname = VALUES(game_nickname),
                    updated_at = CURRENT_TIMESTAMP
                """,
                (user_id, game_nickname),
            )
