#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-support-bot}"
APP_DIR="${APP_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
RUN_USER="${RUN_USER:-$(id -un)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$APP_DIR/.venv}"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
MANAGE_SH_URL="${MANAGE_SH_URL:-}"
MANAGE_AUTOOPEN_START="# >>> support-bot manage auto-open >>>"
MANAGE_AUTOOPEN_END="# <<< support-bot manage auto-open <<<"
SUDO_CMD=""

log() {
  printf "[install] %s\n" "$1"
}

die() {
  printf "[install] ERROR: %s\n" "$1" >&2
  exit 1
}

usage() {
  cat <<EOF
Использование:
  ./install.sh                 # интерактивное меню установки
  ./install.sh full            # полная установка
  ./install.sh env             # настроить BOT_TOKEN/ADMIN_CHAT_ID и БД в .env
  ./install.sh check           # проверка проекта и .env
  ./install.sh components      # системные компоненты (python3/venv/pip)
  ./install.sh python          # .venv + pip install -r requirements.txt
  ./install.sh service         # создать/обновить systemd-сервис
  ./install.sh manage [URL]    # скачать manage.sh (скрипт управления)
  ./install.sh open            # открыть manage.sh (меню управления)
  ./install.sh auto-on         # включить авто-открытие manage.sh при SSH-входе
  ./install.sh auto-off        # выключить авто-открытие manage.sh при SSH-входе
  ./install.sh purge           # полностью удалить бота с VDS

Русские алиасы:
  полная, окружение, проверка, компоненты, питон, сервис, управление, открыть, авто-вкл, авто-выкл, удалить, помощь

Примечание:
  Запуск/остановка/логи бота выполняются через manage.sh.

Переменные окружения:
  SERVICE_NAME=$SERVICE_NAME
  APP_DIR=$APP_DIR
  RUN_USER=$RUN_USER
  PYTHON_BIN=$PYTHON_BIN
  VENV_DIR=$VENV_DIR
  MANAGE_SH_URL=$MANAGE_SH_URL
EOF
}

detect_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO_CMD=""
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    SUDO_CMD="sudo"
    return
  fi

  die "Запусти от root или установи sudo."
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Команда не найдена: $cmd"
  fi
}

check_project_files() {
  [[ -f "$APP_DIR/bot.py" ]] || die "Не найден $APP_DIR/bot.py"
  [[ -f "$APP_DIR/requirements.txt" ]] || die "Не найден $APP_DIR/requirements.txt"
}

ensure_env_file_exists() {
  if [[ -f "$APP_DIR/.env" ]]; then
    return
  fi

  if [[ -f "$APP_DIR/.env.example" ]]; then
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    log "Создан .env из .env.example"
    return
  fi

  cat >"$APP_DIR/.env" <<'EOF'
BOT_TOKEN=
ADMIN_CHAT_ID=

DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=root
DB_PASSWORD=
DB_NAME=vega_supportbot
EOF
  log "Создан базовый .env"
}

get_env_value() {
  local key="$1"
  if [[ ! -f "$APP_DIR/.env" ]]; then
    return
  fi
  local line
  line="$(grep -E "^${key}=" "$APP_DIR/.env" | head -n 1 || true)"
  printf "%s" "${line#*=}"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped

  escaped="$(printf "%s" "$value" | sed -e 's/[&|\\]/\\&/g')"
  if grep -Eq "^${key}=" "$APP_DIR/.env"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$APP_DIR/.env"
  else
    printf "%s=%s\n" "$key" "$value" >>"$APP_DIR/.env"
  fi
}

setup_bot_identity() {
  ensure_env_file_exists

  if [[ ! -t 0 ]]; then
    log "Неинтерактивный режим: настройка BOT_TOKEN/ADMIN_CHAT_ID пропущена."
    return
  fi

  local current_token
  local current_chat_id
  local current_db_host
  local current_db_port
  local current_db_user
  local current_db_password
  local current_db_name
  local token
  local chat_id
  local db_host
  local db_port
  local db_user
  local db_password
  local db_name

  current_token="$(get_env_value BOT_TOKEN)"
  current_chat_id="$(get_env_value ADMIN_CHAT_ID)"
  current_db_host="$(get_env_value DB_HOST)"
  current_db_port="$(get_env_value DB_PORT)"
  current_db_user="$(get_env_value DB_USER)"
  current_db_password="$(get_env_value DB_PASSWORD)"
  current_db_name="$(get_env_value DB_NAME)"

  if [[ "$current_token" == "your_bot_token_here" ]]; then
    current_token=""
  fi
  if [[ "$current_chat_id" == "-1000000000000" ]]; then
    current_chat_id=""
  fi
  if [[ -z "$current_db_host" ]]; then
    current_db_host="127.0.0.1"
  fi
  if [[ -z "$current_db_port" ]]; then
    current_db_port="3306"
  fi
  if [[ -z "$current_db_user" ]]; then
    current_db_user="root"
  fi
  if [[ "$current_db_password" == "your_db_password_here" ]]; then
    current_db_password=""
  fi
  if [[ -z "$current_db_name" ]]; then
    current_db_name="vega_supportbot"
  fi

  echo
  echo "Настройка .env"
  if [[ -n "$current_token" ]]; then
    echo "Текущий BOT_TOKEN уже задан."
  fi
  if [[ -n "$current_chat_id" ]]; then
    echo "Текущий ADMIN_CHAT_ID: $current_chat_id"
  fi

  read -r -p "Введи BOT_TOKEN ${current_token:+(Enter = оставить текущий)}: " token
  if [[ -z "$token" ]]; then
    token="$current_token"
  fi

  read -r -p "Введи ADMIN_CHAT_ID ${current_chat_id:+(Enter = оставить текущий)}: " chat_id
  if [[ -z "$chat_id" ]]; then
    chat_id="$current_chat_id"
  fi

  read -r -p "Введи DB_HOST (Enter = ${current_db_host}): " db_host
  if [[ -z "$db_host" ]]; then
    db_host="$current_db_host"
  fi

  read -r -p "Введи DB_PORT (Enter = ${current_db_port}): " db_port
  if [[ -z "$db_port" ]]; then
    db_port="$current_db_port"
  fi

  read -r -p "Введи DB_USER (Enter = ${current_db_user}): " db_user
  if [[ -z "$db_user" ]]; then
    db_user="$current_db_user"
  fi

  read -r -s -p "Введи DB_PASSWORD (Enter = оставить текущий): " db_password
  echo
  if [[ -z "$db_password" ]]; then
    db_password="$current_db_password"
  fi

  read -r -p "Введи DB_NAME (Enter = ${current_db_name}): " db_name
  if [[ -z "$db_name" ]]; then
    db_name="$current_db_name"
  fi

  if [[ -z "$token" ]]; then
    die "BOT_TOKEN не задан."
  fi
  if [[ -z "$chat_id" ]]; then
    die "ADMIN_CHAT_ID не задан."
  fi
  if [[ ! "$chat_id" =~ ^-?[0-9]+$ ]]; then
    die "ADMIN_CHAT_ID должен быть числом (например: -1001234567890)."
  fi
  if [[ -z "$db_host" ]]; then
    die "DB_HOST не задан."
  fi
  if [[ -z "$db_port" || ! "$db_port" =~ ^[0-9]+$ ]]; then
    die "DB_PORT должен быть числом."
  fi
  if [[ -z "$db_user" ]]; then
    die "DB_USER не задан."
  fi
  if [[ -z "$db_name" ]]; then
    die "DB_NAME не задан."
  fi

  set_env_value BOT_TOKEN "$token"
  set_env_value ADMIN_CHAT_ID "$chat_id"
  set_env_value DB_HOST "$db_host"
  set_env_value DB_PORT "$db_port"
  set_env_value DB_USER "$db_user"
  set_env_value DB_PASSWORD "$db_password"
  set_env_value DB_NAME "$db_name"
  log "Обновлены BOT_TOKEN, ADMIN_CHAT_ID и настройки БД в .env"
}

check_env_keys() {
  ensure_env_file_exists

  local required_keys
  required_keys=(
    BOT_TOKEN
    ADMIN_CHAT_ID
    DB_HOST
    DB_PORT
    DB_USER
    DB_PASSWORD
    DB_NAME
  )

  local missing=()
  local key=""
  for key in "${required_keys[@]}"; do
    if ! grep -Eq "^${key}=" "$APP_DIR/.env"; then
      missing+=("$key")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "В .env не хватает ключей: ${missing[*]}"
  fi

  local bot_token
  local admin_chat_id
  bot_token="$(get_env_value BOT_TOKEN)"
  admin_chat_id="$(get_env_value ADMIN_CHAT_ID)"

  if [[ -z "$bot_token" || "$bot_token" == "your_bot_token_here" ]]; then
    die "BOT_TOKEN не заполнен. Выполни: ./install.sh env"
  fi
  if [[ -z "$admin_chat_id" || "$admin_chat_id" == "-1000000000000" ]]; then
    die "ADMIN_CHAT_ID не заполнен. Выполни: ./install.sh env"
  fi
  if [[ ! "$admin_chat_id" =~ ^-?[0-9]+$ ]]; then
    die "ADMIN_CHAT_ID должен быть числом. Выполни: ./install.sh env"
  fi

  local db_host
  local db_port
  local db_user
  local db_password
  local db_name
  db_host="$(get_env_value DB_HOST)"
  db_port="$(get_env_value DB_PORT)"
  db_user="$(get_env_value DB_USER)"
  db_password="$(get_env_value DB_PASSWORD)"
  db_name="$(get_env_value DB_NAME)"

  if [[ -z "$db_host" ]]; then
    die "DB_HOST не заполнен. Выполни: ./install.sh env"
  fi
  if [[ -z "$db_port" || ! "$db_port" =~ ^[0-9]+$ ]]; then
    die "DB_PORT должен быть числом. Выполни: ./install.sh env"
  fi
  if [[ -z "$db_user" ]]; then
    die "DB_USER не заполнен. Выполни: ./install.sh env"
  fi
  if [[ "$db_password" == "your_db_password_here" ]]; then
    die "DB_PASSWORD содержит шаблон. Выполни: ./install.sh env"
  fi
  if [[ -z "$db_name" ]]; then
    die "DB_NAME не заполнен. Выполни: ./install.sh env"
  fi
}

project_ready_text() {
  if [[ -f "$APP_DIR/bot.py" && -f "$APP_DIR/requirements.txt" && -f "$APP_DIR/.env" ]]; then
    echo "готово"
  else
    echo "не готово"
  fi
}

env_ready_text() {
  local required_keys
  required_keys=(BOT_TOKEN ADMIN_CHAT_ID DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME)
  local key=""
  for key in "${required_keys[@]}"; do
    if ! grep -Eq "^${key}=" "$APP_DIR/.env" 2>/dev/null; then
      echo "ошибки"
      return
    fi
  done

  local bot_token
  local admin_chat_id
  bot_token="$(get_env_value BOT_TOKEN)"
  admin_chat_id="$(get_env_value ADMIN_CHAT_ID)"
  if [[ -z "$bot_token" || "$bot_token" == "your_bot_token_here" ]]; then
    echo "BOT_TOKEN не задан"
    return
  fi
  if [[ -z "$admin_chat_id" || "$admin_chat_id" == "-1000000000000" ]]; then
    echo "ADMIN_CHAT_ID не задан"
    return
  fi
  if [[ ! "$admin_chat_id" =~ ^-?[0-9]+$ ]]; then
    echo "ADMIN_CHAT_ID неверный"
    return
  fi

  echo "готово"
}

venv_ready_text() {
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    echo "готово"
  else
    echo "не готово"
  fi
}

manage_ready_text() {
  if [[ -x "$APP_DIR/manage.sh" ]]; then
    echo "установлен"
  elif [[ -f "$APP_DIR/manage.sh" ]]; then
    echo "есть (без +x)"
  else
    echo "не установлен"
  fi
}

manage_autostart_text() {
  local bashrc="$HOME/.bashrc"
  if [[ -f "$bashrc" ]] && grep -Fq "$MANAGE_AUTOOPEN_START" "$bashrc"; then
    echo "включено"
  else
    echo "выключено"
  fi
}

remove_manage_autostart_block() {
  local bashrc="$HOME/.bashrc"
  local tmp=""
  if [[ ! -f "$bashrc" ]]; then
    return
  fi

  tmp="$(mktemp)"
  awk -v start="$MANAGE_AUTOOPEN_START" -v end="$MANAGE_AUTOOPEN_END" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$bashrc" >"$tmp"
  mv "$tmp" "$bashrc"
}

enable_manage_autostart() {
  local manage_path="$APP_DIR/manage.sh"
  local bashrc="$HOME/.bashrc"

  if [[ ! -f "$manage_path" ]]; then
    echo "manage.sh не найден. Сначала скачай/добавь его (пункт 6)."
    return
  fi

  chmod +x "$manage_path"
  touch "$bashrc"
  remove_manage_autostart_block

  cat >>"$bashrc" <<EOF

$MANAGE_AUTOOPEN_START
if [[ \$- == *i* ]] && [[ -n "\${SSH_TTY:-}" ]] && [[ -z "\${MANAGE_SH_OPENED:-}" ]]; then
  export MANAGE_SH_OPENED=1
  if [[ -x "$manage_path" ]]; then
    "$manage_path"
  fi
fi
$MANAGE_AUTOOPEN_END
EOF

  log "Авто-открытие manage.sh включено в $bashrc"
}

disable_manage_autostart() {
  remove_manage_autostart_block
  log "Авто-открытие manage.sh выключено."
}

ask_manage_autostart_enable() {
  local answer=""
  if [[ ! -t 0 ]]; then
    return 0
  fi

  read -r -p "Включить авто-открытие manage.sh при SSH-входе? [y/N]: " answer
  case "${answer,,}" in
    y|yes|д|да)
      enable_manage_autostart
      ;;
    *)
      log "Авто-открытие manage.sh не включено."
      ;;
  esac
}

purge_bot() {
  detect_sudo
  require_cmd systemctl

  local app_dir="$APP_DIR"
  if [[ -z "$app_dir" || "$app_dir" == "/" || "$app_dir" == "/root" ]]; then
    die "Небезопасный APP_DIR для удаления: '$app_dir'"
  fi

  if [[ ! -t 0 ]]; then
    die "Для полной очистки нужен интерактивный запуск (подтверждение)."
  fi

  echo
  echo "ВНИМАНИЕ: будет полностью удален бот с VDS."
  echo "Сервис: $SERVICE_NAME"
  echo "Папка проекта: $app_dir"
  echo "Системный сервис-файл: $SERVICE_PATH"
  echo
  read -r -p "Для подтверждения введи DELETE: " confirm
  if [[ "$confirm" != "DELETE" ]]; then
    echo "Отменено."
    return
  fi

  disable_manage_autostart || true
  ${SUDO_CMD} systemctl stop "$SERVICE_NAME" || true
  ${SUDO_CMD} systemctl disable "$SERVICE_NAME" || true
  pkill -f "$app_dir/bot.py" || true

  ${SUDO_CMD} rm -f "$SERVICE_PATH"
  ${SUDO_CMD} systemctl daemon-reload || true
  ${SUDO_CMD} systemctl reset-failed || true

  rm -rf "$app_dir"

  echo "Бот полностью удален с VDS."
  echo "Текущую SSH-сессию можно закрыть."
  exit 0
}

service_state_text() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "нет systemd"
    return
  fi
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "запущен"
  else
    echo "остановлен"
  fi
}

autostart_state_text() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "нет systemd"
    return
  fi
  if systemctl is-enabled --quiet "$SERVICE_NAME"; then
    echo "включен"
  else
    echo "выключен"
  fi
}

install_system_packages() {
  detect_sudo
  if command -v apt-get >/dev/null 2>&1; then
    log "Установка пакетов через apt-get..."
    ${SUDO_CMD} apt-get update
    ${SUDO_CMD} apt-get install -y python3 python3-venv python3-pip
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    log "Установка пакетов через dnf..."
    ${SUDO_CMD} dnf install -y python3 python3-pip
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    log "Установка пакетов через yum..."
    ${SUDO_CMD} yum install -y python3 python3-pip
    return
  fi

  die "Неизвестный пакетный менеджер. Установи python3/python3-venv/python3-pip вручную."
}

install_python_deps() {
  check_project_files
  check_env_keys
  require_cmd "$PYTHON_BIN"

  log "Создаю виртуальное окружение: $VENV_DIR"
  "$PYTHON_BIN" -m venv "$VENV_DIR"

  log "Обновляю pip..."
  "$VENV_DIR/bin/python" -m pip install --upgrade pip

  log "Ставлю зависимости из requirements.txt..."
  "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"
}

prepare_project_files() {
  mkdir -p "$APP_DIR/logs"
  if [[ -f "$APP_DIR/manage.sh" ]]; then
    chmod +x "$APP_DIR/manage.sh"
  fi
  chmod +x "$APP_DIR/install.sh"
}

download_manage_script() {
  local url="${1:-$MANAGE_SH_URL}"
  local target="$APP_DIR/manage.sh"

  if [[ -z "$url" && -t 0 ]]; then
    read -r -p "Вставь прямую ссылку на manage.sh (Enter = пропустить): " url
  fi

  if [[ -z "$url" ]]; then
    log "Скачивание manage.sh пропущено."
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    log "Скачиваю manage.sh через curl..."
    curl -fsSL "$url" -o "$target"
  elif command -v wget >/dev/null 2>&1; then
    log "Скачиваю manage.sh через wget..."
    wget -qO "$target" "$url"
  else
    die "Не найден curl или wget. Установи один из них и повтори."
  fi

  chmod +x "$target"
  log "manage.sh установлен: $target"
}

ask_manage_script_install() {
  local answer=""
  if [[ ! -t 0 ]]; then
    return 0
  fi

  read -r -p "Скачать manage.sh для управления ботом? [y/N]: " answer
  case "${answer,,}" in
    y|yes|д|да)
      download_manage_script
      ;;
    *)
      log "Шаг manage.sh пропущен."
      ;;
  esac
}

open_manage_script() {
  local manage_path="$APP_DIR/manage.sh"
  if [[ ! -f "$manage_path" ]]; then
    echo "manage.sh не найден. Сначала скачай/добавь его (пункт 6)."
    return
  fi

  chmod +x "$manage_path"
  log "Открываю меню управления: $manage_path"
  bash "$manage_path"
}

write_systemd_service() {
  detect_sudo
  require_cmd systemctl

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    die "Сначала выполни шаг Python-зависимостей: ./install.sh python"
  fi

  log "Создаю/обновляю systemd-сервис: $SERVICE_PATH"
  ${SUDO_CMD} tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Telegram Support Bot
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $APP_DIR/bot.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  ${SUDO_CMD} systemctl daemon-reload
}

start_service() {
  detect_sudo
  require_cmd systemctl
  log "Включаю автозапуск и запускаю сервис $SERVICE_NAME..."
  ${SUDO_CMD} systemctl enable --now "$SERVICE_NAME"
  ${SUDO_CMD} systemctl status "$SERVICE_NAME" --no-pager || true
}

check_step() {
  check_project_files
  check_env_keys
  log "Проверка пройдена: файлы и .env в порядке."
}

full_install() {
  setup_bot_identity
  check_step
  install_system_packages
  install_python_deps
  prepare_project_files
  write_systemd_service
  start_service
  ask_manage_script_install
  ask_manage_autostart_enable
  log "Готово: полная установка завершена."
}

interactive_menu() {
  while true; do
    local project_state
    local env_state
    local venv_state
    local manage_state
    local manage_autostart_state
    local service_state
    local autostart_state

    project_state="$(project_ready_text)"
    env_state="$(env_ready_text)"
    venv_state="$(venv_ready_text)"
    manage_state="$(manage_ready_text)"
    manage_autostart_state="$(manage_autostart_text)"
    service_state="$(service_state_text)"
    autostart_state="$(autostart_state_text)"

    cat <<EOF

==========================================
Установка и подготовка бота
==========================================
Состояние:
  проект:     $project_state
  .env:       $env_state
  .venv:      $venv_state
  manage.sh:  $manage_state
  авто-manage: $manage_autostart_state
  сервис:     $service_state
  автозапуск: $autostart_state

1) Настроить .env (BOT_TOKEN + ADMIN_CHAT_ID + DB_*)
2) Проверка проекта и .env
3) Установить системные компоненты
4) Установить Python-зависимости (.venv)
5) Создать/обновить systemd-сервис
6) Скачать manage.sh (скрипт управления)
7) Полная установка (все шаги)
8) Открыть manage.sh (управление ботом)
9) Включить авто-открытие manage.sh при SSH-входе
10) Выключить авто-открытие manage.sh
11) Полностью удалить бота с VDS
0) Выход
EOF

    read -r -p "Выбери пункт [0-11]: " choice
    case "$choice" in
      1) setup_bot_identity ;;
      2) check_step ;;
      3) install_system_packages ;;
      4) install_python_deps; prepare_project_files ;;
      5) write_systemd_service ;;
      6) download_manage_script ;;
      7) full_install ;;
      8) open_manage_script ;;
      9) enable_manage_autostart ;;
      10) disable_manage_autostart ;;
      11) purge_bot ;;
      0) exit 0 ;;
      *)
        echo "Неверный выбор. Введи число от 0 до 11."
        ;;
    esac
  done
}

main() {
  local cmd="${1:-}"

  if [[ -z "$cmd" ]]; then
    if [[ -t 0 ]]; then
      interactive_menu
      return
    fi
    usage
    return
  fi

  case "$cmd" in
    full|all|полная)
      full_install
      ;;
    env|setup|окружение)
      setup_bot_identity
      ;;
    check|проверка)
      check_step
      ;;
    components|component|компоненты)
      install_system_packages
      ;;
    python|venv|питон)
      install_python_deps
      prepare_project_files
      ;;
    service|сервис)
      write_systemd_service
      ;;
    manage|manager|управление)
      download_manage_script "${2:-}"
      ;;
    open|run-manage|открыть)
      open_manage_script
      ;;
    auto-on|automanage-on|авто-вкл)
      enable_manage_autostart
      ;;
    auto-off|automanage-off|авто-выкл)
      disable_manage_autostart
      ;;
    purge|remove|удалить)
      purge_bot
      ;;
    -h|--help|help|помощь)
      usage
      ;;
    *)
      echo "Неизвестная команда: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
