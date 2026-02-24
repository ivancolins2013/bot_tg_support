#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-support-bot}"
APP_DIR="${APP_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
RUN_USER="${RUN_USER:-$(id -un)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$APP_DIR/.venv}"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
MANAGE_SH_URL="${MANAGE_SH_URL:-}"
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
  ./install.sh env             # настроить BOT_TOKEN и ADMIN_CHAT_ID в .env
  ./install.sh check           # проверка проекта и .env
  ./install.sh components      # системные компоненты (python3/venv/pip)
  ./install.sh python          # .venv + pip install -r requirements.txt
  ./install.sh service         # создать/обновить systemd-сервис
  ./install.sh manage [URL]    # скачать manage.sh (скрипт управления)

Русские алиасы:
  полная, окружение, проверка, компоненты, питон, сервис, управление, помощь

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
  local token
  local chat_id

  current_token="$(get_env_value BOT_TOKEN)"
  current_chat_id="$(get_env_value ADMIN_CHAT_ID)"

  if [[ "$current_token" == "your_bot_token_here" ]]; then
    current_token=""
  fi
  if [[ "$current_chat_id" == "-1000000000000" ]]; then
    current_chat_id=""
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

  if [[ -z "$token" ]]; then
    die "BOT_TOKEN не задан."
  fi
  if [[ -z "$chat_id" ]]; then
    die "ADMIN_CHAT_ID не задан."
  fi
  if [[ ! "$chat_id" =~ ^-?[0-9]+$ ]]; then
    die "ADMIN_CHAT_ID должен быть числом (например: -1001234567890)."
  fi

  set_env_value BOT_TOKEN "$token"
  set_env_value ADMIN_CHAT_ID "$chat_id"
  log "Обновлены BOT_TOKEN и ADMIN_CHAT_ID в .env"
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
  log "Готово: полная установка завершена."
}

interactive_menu() {
  while true; do
    local project_state
    local env_state
    local venv_state
    local manage_state
    local service_state
    local autostart_state

    project_state="$(project_ready_text)"
    env_state="$(env_ready_text)"
    venv_state="$(venv_ready_text)"
    manage_state="$(manage_ready_text)"
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
  сервис:     $service_state
  автозапуск: $autostart_state

1) Настроить .env (BOT_TOKEN + ADMIN_CHAT_ID)
2) Проверка проекта и .env
3) Установить системные компоненты
4) Установить Python-зависимости (.venv)
5) Создать/обновить systemd-сервис
6) Скачать manage.sh (скрипт управления)
7) Полная установка (все шаги)
0) Выход
EOF

    read -r -p "Выбери пункт [0-7]: " choice
    case "$choice" in
      1) setup_bot_identity ;;
      2) check_step ;;
      3) install_system_packages ;;
      4) install_python_deps; prepare_project_files ;;
      5) write_systemd_service ;;
      6) download_manage_script ;;
      7) full_install ;;
      0) exit 0 ;;
      *)
        echo "Неверный выбор. Введи число от 0 до 7."
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
