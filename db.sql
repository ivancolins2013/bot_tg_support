-- db.sql (VEGA SupportBot Tickets)
-- charset: utf8mb4

CREATE DATABASE IF NOT EXISTS `vega_supportbot`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE `vega_supportbot`;

-- Таблица тикетов
CREATE TABLE IF NOT EXISTS `tickets` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `user_id` BIGINT NOT NULL,
  `username` VARCHAR(64) NULL,
  `category` VARCHAR(32) NOT NULL DEFAULT 'other',
  `topic` VARCHAR(255) NOT NULL,
  `status` ENUM('open','in_work','closed') NOT NULL DEFAULT 'open',

  `admin_thread_id` BIGINT NULL,

  `assigned_admin_id` BIGINT NULL,
  `assigned_admin_username` VARCHAR(64) NULL,

  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),

  KEY `idx_tickets_user_id` (`user_id`),
  KEY `idx_tickets_status` (`status`),
  KEY `idx_tickets_thread` (`admin_thread_id`),
  KEY `idx_tickets_assignee` (`assigned_admin_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Таблица сообщений тикета
CREATE TABLE IF NOT EXISTS `ticket_messages` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `ticket_id` BIGINT UNSIGNED NOT NULL,

  `sender` ENUM('user','admin') NOT NULL,
  `text` TEXT NOT NULL,

  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),

  KEY `idx_msg_ticket_id` (`ticket_id`),
  KEY `idx_msg_created_at` (`created_at`),

  CONSTRAINT `fk_ticket_messages_ticket`
    FOREIGN KEY (`ticket_id`) REFERENCES `tickets` (`id`)
    ON DELETE CASCADE
    ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- User profiles (nickname on game server)
CREATE TABLE IF NOT EXISTS `user_profiles` (
  `user_id` BIGINT NOT NULL,
  `game_nickname` VARCHAR(64) NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
