#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-support-bot}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${ROOT_DIR:-}" ]]; then
  if [[ -d "$SCRIPT_DIR/bot" ]]; then
    ROOT_DIR="$SCRIPT_DIR"
  elif [[ -d "$SCRIPT_DIR/../bot" ]]; then
    ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
  else
    ROOT_DIR="$SCRIPT_DIR"
  fi
fi

BOT_DIR="${BOT_DIR:-$ROOT_DIR/bot}"
RUN_USER="${RUN_USER:-$(id -un)}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$ROOT_DIR/.venv}"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
MANAGE_SH_URL="${MANAGE_SH_URL:-}"
MANAGE_AUTOOPEN_START="# >>> support-bot manage auto-open >>>"
MANAGE_AUTOOPEN_END="# <<< support-bot manage auto-open <<<"
LIST_BOTS_AUTOOPEN_START="# >>> support-bot list-bots auto-open >>>"
LIST_BOTS_AUTOOPEN_END="# <<< support-bot list-bots auto-open <<<"
SUDO_CMD=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR_RESET=$'\033[0m'
  COLOR_BOLD=$'\033[1m'
  COLOR_DIM=$'\033[2m'
  COLOR_RED=$'\033[31m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_BLUE=$'\033[34m'
  COLOR_CYAN=$'\033[36m'
else
  COLOR_RESET=""
  COLOR_BOLD=""
  COLOR_DIM=""
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_CYAN=""
fi

log() {
  printf "%b[install]%b %s\n" "${COLOR_CYAN}${COLOR_BOLD}" "$COLOR_RESET" "$1"
}

die() {
  printf "%b[install] ERROR:%b %s\n" "${COLOR_RED}${COLOR_BOLD}" "$COLOR_RESET" "$1" >&2
  exit 1
}

usage() {
  cat <<EOF
РСЃРїРѕР»СЊР·РѕРІР°РЅРёРµ:
  ./install.sh                 # РёРЅС‚РµСЂР°РєС‚РёРІРЅРѕРµ РјРµРЅСЋ СѓСЃС‚Р°РЅРѕРІРєРё
  ./install.sh full            # РїРѕР»РЅР°СЏ СѓСЃС‚Р°РЅРѕРІРєР°
  ./install.sh env             # РЅР°СЃС‚СЂРѕРёС‚СЊ BOT_TOKEN/ADMIN_CHAT_ID Рё Р‘Р” РІ .env
  ./install.sh check           # РїСЂРѕРІРµСЂРєР° РїСЂРѕРµРєС‚Р° Рё .env
  ./install.sh components      # СЃРёСЃС‚РµРјРЅС‹Рµ РєРѕРјРїРѕРЅРµРЅС‚С‹ (python3/venv/pip)
  ./install.sh python          # .venv + pip install -r requirements.txt
  ./install.sh service         # СЃРѕР·РґР°С‚СЊ/РѕР±РЅРѕРІРёС‚СЊ systemd-СЃРµСЂРІРёСЃ
  ./install.sh manage [URL]    # СЃРєР°С‡Р°С‚СЊ manage.sh (СЃРєСЂРёРїС‚ СѓРїСЂР°РІР»РµРЅРёСЏ)
  ./install.sh open            # РѕС‚РєСЂС‹С‚СЊ manage.sh (РјРµРЅСЋ СѓРїСЂР°РІР»РµРЅРёСЏ)
  ./install.sh auto-on         # РІРєР»СЋС‡РёС‚СЊ Р°РІС‚Рѕ-РѕС‚РєСЂС‹С‚РёРµ manage.sh РїСЂРё SSH-РІС…РѕРґРµ
  ./install.sh auto-off        # РІС‹РєР»СЋС‡РёС‚СЊ Р°РІС‚Рѕ-РѕС‚РєСЂС‹С‚РёРµ manage.sh РїСЂРё SSH-РІС…РѕРґРµ
  ./install.sh purge           # РїРѕР»РЅРѕСЃС‚СЊСЋ СѓРґР°Р»РёС‚СЊ Р±РѕС‚Р° СЃ VDS

Р СѓСЃСЃРєРёРµ Р°Р»РёР°СЃС‹:
  РїРѕР»РЅР°СЏ, РѕРєСЂСѓР¶РµРЅРёРµ, РїСЂРѕРІРµСЂРєР°, РєРѕРјРїРѕРЅРµРЅС‚С‹, РїРёС‚РѕРЅ, СЃРµСЂРІРёСЃ, СѓРїСЂР°РІР»РµРЅРёРµ,
  РѕС‚РєСЂС‹С‚СЊ, Р°РІС‚Рѕ-РІРєР», Р°РІС‚Рѕ-РІС‹РєР», СѓРґР°Р»РёС‚СЊ, РїРѕРјРѕС‰СЊ

РџСЂРёРјРµС‡Р°РЅРёРµ:
  Р—Р°РїСѓСЃРє/РѕСЃС‚Р°РЅРѕРІРєР°/Р»РѕРіРё Р±РѕС‚Р° РІС‹РїРѕР»РЅСЏСЋС‚СЃСЏ С‡РµСЂРµР· manage.sh.

РџРµСЂРµРјРµРЅРЅС‹Рµ РѕРєСЂСѓР¶РµРЅРёСЏ:
  SERVICE_NAME=$SERVICE_NAME
  ROOT_DIR=$ROOT_DIR
  BOT_DIR=$BOT_DIR
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

  die "Р—Р°РїСѓСЃС‚Рё РѕС‚ root РёР»Рё СѓСЃС‚Р°РЅРѕРІРё sudo."
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "РљРѕРјР°РЅРґР° РЅРµ РЅР°Р№РґРµРЅР°: $cmd"
  fi
}

check_layout() {
  if [[ ! -d "$BOT_DIR" ]]; then
    die "РќРµ РЅР°Р№РґРµРЅ РєР°С‚Р°Р»РѕРі Р±РѕС‚Р°: $BOT_DIR"
  fi
}

check_project_files() {
  check_layout
  [[ -f "$BOT_DIR/bot.py" ]] || die "РќРµ РЅР°Р№РґРµРЅ $BOT_DIR/bot.py"
  [[ -f "$BOT_DIR/requirements.txt" ]] || die "РќРµ РЅР°Р№РґРµРЅ $BOT_DIR/requirements.txt"
}

ensure_env_file_exists() {
  check_layout

  if [[ -f "$BOT_DIR/.env" ]]; then
    return
  fi

  if [[ -f "$BOT_DIR/.env.example" ]]; then
    cp "$BOT_DIR/.env.example" "$BOT_DIR/.env"
    log "РЎРѕР·РґР°РЅ .env РёР· .env.example"
    return
  fi

  cat >"$BOT_DIR/.env" <<'EOF'
BOT_TOKEN=
ADMIN_CHAT_ID=
PROJECT_NAME=DETROIT

DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=root
DB_PASSWORD=
DB_NAME=detroit_supportbot
EOF
  log "РЎРѕР·РґР°РЅ Р±Р°Р·РѕРІС‹Р№ .env"
}

get_env_value() {
  local key="$1"
  if [[ ! -f "$BOT_DIR/.env" ]]; then
    return
  fi
  local line
  line="$(grep -E "^${key}=" "$BOT_DIR/.env" | head -n 1 || true)"
  printf "%s" "${line#*=}"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped

  escaped="$(printf "%s" "$value" | sed -e 's/[&|\\]/\\&/g')"
  if grep -Eq "^${key}=" "$BOT_DIR/.env"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$BOT_DIR/.env"
  else
    printf "%s=%s\n" "$key" "$value" >>"$BOT_DIR/.env"
  fi
}

read_secret() {
  local __var="$1"
  local prompt="$2"
  local value=""

  if [[ ! -t 0 ]]; then
    printf -v "$__var" ""
    return
  fi

  printf "%s" "$prompt"
  if command -v stty >/dev/null 2>&1; then
    stty -echo 2>/dev/null || true
    IFS= read -r value
    stty echo 2>/dev/null || true
    if [[ -n "$value" ]]; then
      printf "%s" "$(printf '%*s' "${#value}" '' | tr ' ' '*')"
    fi
    echo
  else
    IFS= read -r -s value
    echo
  fi

  printf -v "$__var" "%s" "$value"
}

setup_bot_identity() {
  ensure_env_file_exists

  if [[ ! -t 0 ]]; then
    log "РќРµРёРЅС‚РµСЂР°РєС‚РёРІРЅС‹Р№ СЂРµР¶РёРј: РЅР°СЃС‚СЂРѕР№РєР° BOT_TOKEN/ADMIN_CHAT_ID РїСЂРѕРїСѓС‰РµРЅР°."
    return
  fi

  local current_token
  local current_chat_id
  local current_project_name
  local current_db_host
  local current_db_port
  local current_db_user
  local current_db_password
  local current_db_name
  local token
  local chat_id
  local project_name
  local db_host
  local db_port
  local db_user
  local db_password
  local db_name

  current_token="$(get_env_value BOT_TOKEN)"
  current_chat_id="$(get_env_value ADMIN_CHAT_ID)"
  current_project_name="$(get_env_value PROJECT_NAME)"
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
  if [[ -z "$current_project_name" ]]; then
    current_project_name="DETROIT"
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
    current_db_name="detroit_supportbot"
  fi

  echo
  echo "РќР°СЃС‚СЂРѕР№РєР° .env"
  if [[ -n "$current_token" ]]; then
    echo "РўРµРєСѓС‰РёР№ BOT_TOKEN СѓР¶Рµ Р·Р°РґР°РЅ."
  fi
  if [[ -n "$current_chat_id" ]]; then
    echo "РўРµРєСѓС‰РёР№ ADMIN_CHAT_ID: $current_chat_id"
  fi

  read -r -p "Р’РІРµРґРё BOT_TOKEN ${current_token:+(Enter = РѕСЃС‚Р°РІРёС‚СЊ С‚РµРєСѓС‰РёР№)}: " token
  if [[ -z "$token" ]]; then
    token="$current_token"
  fi

  read -r -p "Р’РІРµРґРё ADMIN_CHAT_ID ${current_chat_id:+(Enter = РѕСЃС‚Р°РІРёС‚СЊ С‚РµРєСѓС‰РёР№)}: " chat_id
  if [[ -z "$chat_id" ]]; then
    chat_id="$current_chat_id"
  fi

  read -r -p "Р’РІРµРґРё PROJECT_NAME (Enter = ${current_project_name}): " project_name
  if [[ -z "$project_name" ]]; then
    project_name="$current_project_name"
  fi

  read -r -p "Р’РІРµРґРё DB_HOST (Enter = ${current_db_host}): " db_host
  if [[ -z "$db_host" ]]; then
    db_host="$current_db_host"
  fi

  read -r -p "Р’РІРµРґРё DB_PORT (Enter = ${current_db_port}): " db_port
  if [[ -z "$db_port" ]]; then
    db_port="$current_db_port"
  fi

  read -r -p "Р’РІРµРґРё DB_USER (Enter = ${current_db_user}): " db_user
  if [[ -z "$db_user" ]]; then
    db_user="$current_db_user"
  fi

  read_secret db_password "Р’РІРµРґРё DB_PASSWORD (Enter = РѕСЃС‚Р°РІРёС‚СЊ С‚РµРєСѓС‰РёР№): "
  if [[ -z "$db_password" ]]; then
    db_password="$current_db_password"
  fi

  read -r -p "Р’РІРµРґРё DB_NAME (Enter = ${current_db_name}): " db_name
  if [[ -z "$db_name" ]]; then
    db_name="$current_db_name"
  fi

  if [[ -z "$token" ]]; then
    die "BOT_TOKEN РЅРµ Р·Р°РґР°РЅ."
  fi
  if [[ -z "$chat_id" ]]; then
    die "ADMIN_CHAT_ID РЅРµ Р·Р°РґР°РЅ."
  fi
  if [[ ! "$chat_id" =~ ^-?[0-9]+$ ]]; then
    die "ADMIN_CHAT_ID РґРѕР»Р¶РµРЅ Р±С‹С‚СЊ С‡РёСЃР»РѕРј (РЅР°РїСЂРёРјРµСЂ: -1001234567890)."
  fi
  if [[ -z "$project_name" ]]; then
    die "PROJECT_NAME РЅРµ Р·Р°РґР°РЅ."
  fi
  if [[ -z "$db_host" ]]; then
    die "DB_HOST РЅРµ Р·Р°РґР°РЅ."
  fi
  if [[ -z "$db_port" || ! "$db_port" =~ ^[0-9]+$ ]]; then
    die "DB_PORT РґРѕР»Р¶РµРЅ Р±С‹С‚СЊ С‡РёСЃР»РѕРј."
  fi
  if [[ -z "$db_user" ]]; then
    die "DB_USER РЅРµ Р·Р°РґР°РЅ."
  fi
  if [[ -z "$db_name" ]]; then
    die "DB_NAME РЅРµ Р·Р°РґР°РЅ."
  fi

  set_env_value BOT_TOKEN "$token"
  set_env_value ADMIN_CHAT_ID "$chat_id"
  set_env_value PROJECT_NAME "$project_name"
  set_env_value DB_HOST "$db_host"
  set_env_value DB_PORT "$db_port"
  set_env_value DB_USER "$db_user"
  set_env_value DB_PASSWORD "$db_password"
  set_env_value DB_NAME "$db_name"
  log "РћР±РЅРѕРІР»РµРЅС‹ BOT_TOKEN, ADMIN_CHAT_ID Рё РЅР°СЃС‚СЂРѕР№РєРё Р‘Р” РІ .env"
}

check_env_keys() {
  ensure_env_file_exists

  local required_keys
  required_keys=(
    BOT_TOKEN
    ADMIN_CHAT_ID
    PROJECT_NAME
    DB_HOST
    DB_PORT
    DB_USER
    DB_PASSWORD
    DB_NAME
  )

  local missing=()
  local key=""
  for key in "${required_keys[@]}"; do
    if ! grep -Eq "^${key}=" "$BOT_DIR/.env"; then
      missing+=("$key")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "Р’ .env РЅРµ С…РІР°С‚Р°РµС‚ РєР»СЋС‡РµР№: ${missing[*]}"
  fi

  local bot_token
  local admin_chat_id
  local project_name
  bot_token="$(get_env_value BOT_TOKEN)"
  admin_chat_id="$(get_env_value ADMIN_CHAT_ID)"
  project_name="$(get_env_value PROJECT_NAME)"

  if [[ -z "$bot_token" || "$bot_token" == "your_bot_token_here" ]]; then
    die "BOT_TOKEN РЅРµ Р·Р°РїРѕР»РЅРµРЅ. Р’С‹РїРѕР»РЅРё: ./install.sh env"
  fi
  if [[ -z "$admin_chat_id" || "$admin_chat_id" == "-1000000000000" ]]; then
    die "ADMIN_CHAT_ID РЅРµ Р·Р°РїРѕР»РЅРµРЅ. Р’С‹РїРѕР»РЅРё: ./install.sh env"
  fi
  if [[ ! "$admin_chat_id" =~ ^-?[0-9]+$ ]]; then
    die "ADMIN_CHAT_ID РґРѕР»Р¶РµРЅ Р±С‹С‚СЊ С‡РёСЃР»РѕРј. Р’С‹РїРѕР»РЅРё: ./install.sh env"
  fi
  if [[ -z "$project_name" ]]; then
    die "PROJECT_NAME РЅРµ Р·Р°РїРѕР»РЅРµРЅ. Р’С‹РїРѕР»РЅРё: ./install.sh env"
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
    die "DB_HOST РЅРµ Р·Р°РїРѕР»РЅРµРЅ. Р’С‹РїРѕР»РЅРё: ./install.sh env"
  fi
  if [[ -z "$db_port" || ! "$db_port" =~ ^[0-9]+$ ]]; then
    die "DB_PORT РґРѕР»Р¶РµРЅ Р±С‹С‚СЊ С‡РёСЃР»РѕРј. Р’С‹РїРѕР»РЅРё: ./install.sh env"
  fi
  if [[ -z "$db_user" ]]; then
    die "DB_USER РЅРµ Р·Р°РїРѕР»РЅРµРЅ. Р’С‹РїРѕР»РЅРё: ./install.sh env"
  fi
  if [[ "$db_password" == "your_db_password_here" ]]; then
    die "DB_PASSWORD СЃРѕРґРµСЂР¶РёС‚ С€Р°Р±Р»РѕРЅ. Р’С‹РїРѕР»РЅРё: ./install.sh env"
  fi
  if [[ -z "$db_name" ]]; then
    die "DB_NAME РЅРµ Р·Р°РїРѕР»РЅРµРЅ. Р’С‹РїРѕР»РЅРё: ./install.sh env"
  fi
}

project_ready_text() {
  if [[ -f "$BOT_DIR/bot.py" && -f "$BOT_DIR/requirements.txt" && -f "$BOT_DIR/.env" ]]; then
    echo "РіРѕС‚РѕРІРѕ"
  else
    echo "РЅРµ РіРѕС‚РѕРІРѕ"
  fi
}

env_ready_text() {
  local required_keys
  required_keys=(BOT_TOKEN ADMIN_CHAT_ID PROJECT_NAME DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME)
  local key=""
  for key in "${required_keys[@]}"; do
    if ! grep -Eq "^${key}=" "$BOT_DIR/.env" 2>/dev/null; then
      echo "РѕС€РёР±РєРё"
      return
    fi
  done

  local bot_token
  local admin_chat_id
  local project_name
  bot_token="$(get_env_value BOT_TOKEN)"
  admin_chat_id="$(get_env_value ADMIN_CHAT_ID)"
  project_name="$(get_env_value PROJECT_NAME)"
  if [[ -z "$bot_token" || "$bot_token" == "your_bot_token_here" ]]; then
    echo "BOT_TOKEN РЅРµ Р·Р°РґР°РЅ"
    return
  fi
  if [[ -z "$admin_chat_id" || "$admin_chat_id" == "-1000000000000" ]]; then
    echo "ADMIN_CHAT_ID РЅРµ Р·Р°РґР°РЅ"
    return
  fi
  if [[ ! "$admin_chat_id" =~ ^-?[0-9]+$ ]]; then
    echo "ADMIN_CHAT_ID РЅРµРІРµСЂРЅС‹Р№"
    return
  fi
  if [[ -z "$project_name" ]]; then
    echo "PROJECT_NAME РЅРµ Р·Р°РґР°РЅ"
    return
  fi

  echo "РіРѕС‚РѕРІРѕ"
}

venv_ready_text() {
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    echo "РіРѕС‚РѕРІРѕ"
  else
    echo "РЅРµ РіРѕС‚РѕРІРѕ"
  fi
}

manage_ready_text() {
  if [[ -x "$SCRIPT_DIR/manage.sh" ]]; then
    echo "СѓСЃС‚Р°РЅРѕРІР»РµРЅ"
  elif [[ -f "$SCRIPT_DIR/manage.sh" ]]; then
    echo "РµСЃС‚СЊ (Р±РµР· +x)"
  else
    echo "РЅРµ СѓСЃС‚Р°РЅРѕРІР»РµРЅ"
  fi
}

manage_autostart_text() {
  local bashrc="$HOME/.bashrc"
  if [[ -f "$bashrc" ]] && grep -Fq "$MANAGE_AUTOOPEN_START" "$bashrc"; then
    echo "РІРєР»СЋС‡РµРЅРѕ"
  else
    echo "РІС‹РєР»СЋС‡РµРЅРѕ"
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
  local manage_path="$SCRIPT_DIR/manage.sh"
  local bashrc="$HOME/.bashrc"

  if [[ ! -f "$manage_path" ]]; then
    echo "manage.sh РЅРµ РЅР°Р№РґРµРЅ. РЎРЅР°С‡Р°Р»Р° СЃРєР°С‡Р°Р№/РґРѕР±Р°РІСЊ РµРіРѕ (РїСѓРЅРєС‚ 6)."
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

  log "РђРІС‚Рѕ-РѕС‚РєСЂС‹С‚РёРµ manage.sh РІРєР»СЋС‡РµРЅРѕ РІ $bashrc"
}

disable_manage_autostart() {
  remove_manage_autostart_block
  log "РђРІС‚Рѕ-РѕС‚РєСЂС‹С‚РёРµ manage.sh РІС‹РєР»СЋС‡РµРЅРѕ."
}

ask_manage_autostart_enable() {
  local answer=""
  if [[ ! -t 0 ]]; then
    return 0
  fi

  read -r -p "Р’РєР»СЋС‡РёС‚СЊ Р°РІС‚Рѕ-РѕС‚РєСЂС‹С‚РёРµ manage.sh РїСЂРё SSH-РІС…РѕРґРµ? [y/N]: " answer
  case "${answer,,}" in
    y|yes|Рґ|РґР°)
      enable_manage_autostart
      ;;
    *)
      log "РђРІС‚Рѕ-РѕС‚РєСЂС‹С‚РёРµ manage.sh РЅРµ РІРєР»СЋС‡РµРЅРѕ."
      ;;
  esac
}

remove_list_bots_autostart_block() {
  local bashrc="$HOME/.bashrc"
  local tmp=""
  if [[ ! -f "$bashrc" ]]; then
    return
  fi

  tmp="$(mktemp)"
  awk -v start="$LIST_BOTS_AUTOOPEN_START" -v end="$LIST_BOTS_AUTOOPEN_END" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$bashrc" >"$tmp"
  mv "$tmp" "$bashrc"
}

enable_list_bots_autostart() {
  local list_bots_path="$SCRIPT_DIR/list_bots.sh"
  local bashrc="$HOME/.bashrc"

  if [[ ! -f "$list_bots_path" ]]; then
    log "list_bots.sh not found near install.sh; list auto-open was not enabled."
    return
  fi

  chmod +x "$list_bots_path"
  touch "$bashrc"
  remove_manage_autostart_block
  remove_list_bots_autostart_block

  cat >>"$bashrc" <<EOF

$LIST_BOTS_AUTOOPEN_START
if [[ \$- == *i* ]] && [[ -n "\${SSH_TTY:-}" ]] && [[ -z "\${LIST_BOTS_SH_OPENED:-}" ]]; then
  export LIST_BOTS_SH_OPENED=1
  if [[ -x "$list_bots_path" ]]; then
    "$list_bots_path"
  fi
fi
$LIST_BOTS_AUTOOPEN_END
EOF

  log "List auto-open enabled in $bashrc"
}

ask_list_bots_autostart_enable() {
  local answer=""
  if [[ ! -t 0 ]]; then
    return 0
  fi

  read -r -p "Enable auto-open of list_bots.sh at SSH login? (recommended if you have many bots) [y/N]: " answer
  case "${answer,,}" in
    y|yes)
      enable_list_bots_autostart
      ;;
    *)
      log "List auto-open was not enabled."
      ;;
  esac
}

purge_bot() {
  detect_sudo
  require_cmd systemctl

  local app_dir="$ROOT_DIR"
  if [[ -z "$app_dir" || "$app_dir" == "/" || "$app_dir" == "/root" ]]; then
    die "РќРµР±РµР·РѕРїР°СЃРЅС‹Р№ ROOT_DIR РґР»СЏ СѓРґР°Р»РµРЅРёСЏ: '$app_dir'"
  fi

  if [[ ! -t 0 ]]; then
    die "Р”Р»СЏ РїРѕР»РЅРѕР№ РѕС‡РёСЃС‚РєРё РЅСѓР¶РµРЅ РёРЅС‚РµСЂР°РєС‚РёРІРЅС‹Р№ Р·Р°РїСѓСЃРє (РїРѕРґС‚РІРµСЂР¶РґРµРЅРёРµ)."
  fi

  echo
  echo "Р’РќРРњРђРќРР•: Р±СѓРґРµС‚ СѓРґР°Р»РµРЅ Р±РѕС‚ СЃ VDS."
  echo "РЎРµСЂРІРёСЃ: $SERVICE_NAME"
  echo "РџР°РїРєР° РїСЂРѕРµРєС‚Р°: $app_dir"
  echo "РЎРёСЃС‚РµРјРЅС‹Р№ СЃРµСЂРІРёСЃ-С„Р°Р№Р»: $SERVICE_PATH"
  echo
  read -r -p "Р”Р»СЏ РїРѕРґС‚РІРµСЂР¶РґРµРЅРёСЏ РІРІРµРґРё DELETE: " confirm
  if [[ "$confirm" != "DELETE" ]]; then
    echo "РћС‚РјРµРЅРµРЅРѕ."
    return
  fi

  disable_manage_autostart || true
  ${SUDO_CMD} systemctl stop "$SERVICE_NAME" || true
  ${SUDO_CMD} systemctl disable "$SERVICE_NAME" || true
  pkill -f "$BOT_DIR/bot.py" || true

  ${SUDO_CMD} rm -f "$SERVICE_PATH"
  ${SUDO_CMD} systemctl daemon-reload || true
  ${SUDO_CMD} systemctl reset-failed || true

  rm -rf "$app_dir"

  echo "Р‘РѕС‚ РїРѕР»РЅРѕСЃС‚СЊСЋ СѓРґР°Р»РµРЅ СЃ VDS."
  echo "РўРµРєСѓС‰СѓСЋ SSH-СЃРµСЃСЃРёСЋ РјРѕР¶РЅРѕ Р·Р°РєСЂС‹С‚СЊ."
  exit 0
}

service_state_text() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "РЅРµС‚ systemd"
    return
  fi
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "Р·Р°РїСѓС‰РµРЅ"
  else
    echo "РѕСЃС‚Р°РЅРѕРІР»РµРЅ"
  fi
}

autostart_state_text() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "РЅРµС‚ systemd"
    return
  fi
  if systemctl is-enabled --quiet "$SERVICE_NAME"; then
    echo "РІРєР»СЋС‡РµРЅ"
  else
    echo "РІС‹РєР»СЋС‡РµРЅ"
  fi
}

install_system_packages() {
  detect_sudo
  if command -v apt-get >/dev/null 2>&1; then
    log "РЈСЃС‚Р°РЅРѕРІРєР° РїР°РєРµС‚РѕРІ С‡РµСЂРµР· apt-get..."
    ${SUDO_CMD} apt-get update
    ${SUDO_CMD} apt-get install -y python3 python3-venv python3-pip
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    log "РЈСЃС‚Р°РЅРѕРІРєР° РїР°РєРµС‚РѕРІ С‡РµСЂРµР· dnf..."
    ${SUDO_CMD} dnf install -y python3 python3-pip
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    log "РЈСЃС‚Р°РЅРѕРІРєР° РїР°РєРµС‚РѕРІ С‡РµСЂРµР· yum..."
    ${SUDO_CMD} yum install -y python3 python3-pip
    return
  fi

  die "РќРµРёР·РІРµСЃС‚РЅС‹Р№ РїР°РєРµС‚РЅС‹Р№ РјРµРЅРµРґР¶РµСЂ. РЈСЃС‚Р°РЅРѕРІРё python3/python3-venv/python3-pip РІСЂСѓС‡РЅСѓСЋ."
}

install_python_deps() {
  check_project_files
  check_env_keys
  require_cmd "$PYTHON_BIN"

  log "РЎРѕР·РґР°СЋ РІРёСЂС‚СѓР°Р»СЊРЅРѕРµ РѕРєСЂСѓР¶РµРЅРёРµ: $VENV_DIR"
  "$PYTHON_BIN" -m venv "$VENV_DIR"

  log "РћР±РЅРѕРІР»СЏСЋ pip..."
  "$VENV_DIR/bin/python" -m pip install --upgrade pip

  log "РЎС‚Р°РІР»СЋ Р·Р°РІРёСЃРёРјРѕСЃС‚Рё РёР· requirements.txt..."
  "$VENV_DIR/bin/pip" install -r "$BOT_DIR/requirements.txt"
}

prepare_project_files() {
  mkdir -p "$BOT_DIR/logs"
  if [[ -f "$SCRIPT_DIR/manage.sh" ]]; then
    chmod +x "$SCRIPT_DIR/manage.sh"
  fi
  chmod +x "$SCRIPT_DIR/install.sh" || true
}

download_manage_script() {
  local url="${1:-$MANAGE_SH_URL}"
  local target="$SCRIPT_DIR/manage.sh"

  if [[ -z "$url" && -t 0 ]]; then
    read -r -p "Р’СЃС‚Р°РІСЊ РїСЂСЏРјСѓСЋ СЃСЃС‹Р»РєСѓ РЅР° manage.sh (Enter = РїСЂРѕРїСѓСЃС‚РёС‚СЊ): " url
  fi

  if [[ -z "$url" ]]; then
    log "РЎРєР°С‡РёРІР°РЅРёРµ manage.sh РїСЂРѕРїСѓС‰РµРЅРѕ."
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    log "РЎРєР°С‡РёРІР°СЋ manage.sh С‡РµСЂРµР· curl..."
    curl -fsSL "$url" -o "$target"
  elif command -v wget >/dev/null 2>&1; then
    log "РЎРєР°С‡РёРІР°СЋ manage.sh С‡РµСЂРµР· wget..."
    wget -qO "$target" "$url"
  else
    die "РќРµ РЅР°Р№РґРµРЅ curl РёР»Рё wget. РЈСЃС‚Р°РЅРѕРІРё РѕРґРёРЅ РёР· РЅРёС… Рё РїРѕРІС‚РѕСЂРё."
  fi

  chmod +x "$target"
  log "manage.sh СѓСЃС‚Р°РЅРѕРІР»РµРЅ: $target"
}

ask_manage_script_install() {
  local answer=""
  if [[ ! -t 0 ]]; then
    return 0
  fi

  if [[ -f "$SCRIPT_DIR/manage.sh" ]]; then
    return 0
  fi

  read -r -p "РЎРєР°С‡Р°С‚СЊ manage.sh РґР»СЏ СѓРїСЂР°РІР»РµРЅРёСЏ Р±РѕС‚РѕРј? [y/N]: " answer
  case "${answer,,}" in
    y|yes|Рґ|РґР°)
      download_manage_script
      ;;
    *)
      log "РЁР°Рі manage.sh РїСЂРѕРїСѓС‰РµРЅ."
      ;;
  esac
}

open_manage_script() {
  local manage_path="$SCRIPT_DIR/manage.sh"
  if [[ ! -f "$manage_path" ]]; then
    echo "manage.sh РЅРµ РЅР°Р№РґРµРЅ. РЎРЅР°С‡Р°Р»Р° СЃРєР°С‡Р°Р№/РґРѕР±Р°РІСЊ РµРіРѕ (РїСѓРЅРєС‚ 6)."
    return
  fi

  chmod +x "$manage_path"
  log "РћС‚РєСЂС‹РІР°СЋ РјРµРЅСЋ СѓРїСЂР°РІР»РµРЅРёСЏ: $manage_path"
  bash "$manage_path"
}

write_systemd_service() {
  detect_sudo
  require_cmd systemctl

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    die "РЎРЅР°С‡Р°Р»Р° РІС‹РїРѕР»РЅРё С€Р°Рі Python-Р·Р°РІРёСЃРёРјРѕСЃС‚РµР№: ./install.sh python"
  fi

  log "РЎРѕР·РґР°СЋ/РѕР±РЅРѕРІР»СЏСЋ systemd-СЃРµСЂРІРёСЃ: $SERVICE_PATH"
  ${SUDO_CMD} tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=Telegram Support Bot
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$BOT_DIR
ExecStart=$VENV_DIR/bin/python $BOT_DIR/bot.py
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
  log "Р’РєР»СЋС‡Р°СЋ Р°РІС‚РѕР·Р°РїСѓСЃРє Рё Р·Р°РїСѓСЃРєР°СЋ СЃРµСЂРІРёСЃ $SERVICE_NAME..."
  ${SUDO_CMD} systemctl enable --now "$SERVICE_NAME"
  ${SUDO_CMD} systemctl status "$SERVICE_NAME" --no-pager || true
}

check_step() {
  check_project_files
  check_env_keys
  log "РџСЂРѕРІРµСЂРєР° РїСЂРѕР№РґРµРЅР°: С„Р°Р№Р»С‹ Рё .env РІ РїРѕСЂСЏРґРєРµ."
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
  ask_list_bots_autostart_enable
  log "Р“РѕС‚РѕРІРѕ: РїРѕР»РЅР°СЏ СѓСЃС‚Р°РЅРѕРІРєР° Р·Р°РІРµСЂС€РµРЅР°."
}

menu_header() {
  local title="$1"
  local line="=========================================="
  echo
  printf "%b%s%b\n" "${COLOR_CYAN}${COLOR_BOLD}" "$line" "$COLOR_RESET"
  printf "%b%s%b\n" "${COLOR_CYAN}${COLOR_BOLD}" "$title" "$COLOR_RESET"
  printf "%b%s%b\n" "${COLOR_CYAN}${COLOR_BOLD}" "$line" "$COLOR_RESET"
}

menu_item() {
  local number="$1"
  local text="$2"
  printf "%b%s)%b %s\n" "${COLOR_BLUE}${COLOR_BOLD}" "$number" "$COLOR_RESET" "$text"
}

colorize_state() {
  local state="${1:-}"
  case "$state" in
    "РіРѕС‚РѕРІРѕ"|"СѓСЃС‚Р°РЅРѕРІР»РµРЅ"|"РІРєР»СЋС‡РµРЅ"|"РІРєР»СЋС‡РµРЅРѕ"|"Р·Р°РїСѓС‰РµРЅ")
      printf "%b%s%b" "$COLOR_GREEN" "$state" "$COLOR_RESET"
      ;;
    "РЅРµ РіРѕС‚РѕРІРѕ"|"РѕС€РёР±РєРё"|"РЅРµ СѓСЃС‚Р°РЅРѕРІР»РµРЅ"|"РѕСЃС‚Р°РЅРѕРІР»РµРЅ"|"РІС‹РєР»СЋС‡РµРЅ"|"РІС‹РєР»СЋС‡РµРЅРѕ"|"РЅРµС‚ systemd"|*"РЅРµ Р·Р°РґР°РЅ"*|*"РЅРµРІРµСЂРЅС‹Р№"*)
      printf "%b%s%b" "$COLOR_RED" "$state" "$COLOR_RESET"
      ;;
    *)
      printf "%b%s%b" "$COLOR_YELLOW" "$state" "$COLOR_RESET"
      ;;
  esac
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

    project_state="$(colorize_state "$(project_ready_text)")"
    env_state="$(colorize_state "$(env_ready_text)")"
    venv_state="$(colorize_state "$(venv_ready_text)")"
    manage_state="$(colorize_state "$(manage_ready_text)")"
    manage_autostart_state="$(colorize_state "$(manage_autostart_text)")"
    service_state="$(colorize_state "$(service_state_text)")"
    autostart_state="$(colorize_state "$(autostart_state_text)")"

    menu_header "РЈСЃС‚Р°РЅРѕРІРєР° Рё РїРѕРґРіРѕС‚РѕРІРєР° Р±РѕС‚Р°"
    printf "%bРЎРѕСЃС‚РѕСЏРЅРёРµ:%b\n" "$COLOR_DIM" "$COLOR_RESET"
    printf "  %bРїСЂРѕРµРєС‚:%b      %s\n" "${COLOR_BLUE}${COLOR_BOLD}" "$COLOR_RESET" "$project_state"
    printf "  %b.env:%b        %s\n" "${COLOR_BLUE}${COLOR_BOLD}" "$COLOR_RESET" "$env_state"
    printf "  %b.venv:%b       %s\n" "${COLOR_BLUE}${COLOR_BOLD}" "$COLOR_RESET" "$venv_state"
    printf "  %bmanage.sh:%b   %s\n" "${COLOR_BLUE}${COLOR_BOLD}" "$COLOR_RESET" "$manage_state"
    printf "  %bР°РІС‚Рѕ-manage:%b %s\n" "${COLOR_BLUE}${COLOR_BOLD}" "$COLOR_RESET" "$manage_autostart_state"
    printf "  %bСЃРµСЂРІРёСЃ:%b      %s\n" "${COLOR_BLUE}${COLOR_BOLD}" "$COLOR_RESET" "$service_state"
    printf "  %bР°РІС‚РѕР·Р°РїСѓСЃРє:%b  %s\n" "${COLOR_BLUE}${COLOR_BOLD}" "$COLOR_RESET" "$autostart_state"
    echo

    menu_item "1" "РџРѕР»РЅР°СЏ СѓСЃС‚Р°РЅРѕРІРєР° (РІСЃРµ С€Р°РіРё) (СЂРµРєРѕРјРµРЅРґСѓРµС‚СЃСЏ)"
    menu_item "2" "РџСЂРѕРІРµСЂРєР° РїСЂРѕРµРєС‚Р° Рё .env"
    menu_item "3" "РЈСЃС‚Р°РЅРѕРІРёС‚СЊ СЃРёСЃС‚РµРјРЅС‹Рµ РєРѕРјРїРѕРЅРµРЅС‚С‹"
    menu_item "4" "РЈСЃС‚Р°РЅРѕРІРёС‚СЊ Python-Р·Р°РІРёСЃРёРјРѕСЃС‚Рё (.venv)"
    menu_item "5" "РЎРѕР·РґР°С‚СЊ/РѕР±РЅРѕРІРёС‚СЊ systemd-СЃРµСЂРІРёСЃ"
    menu_item "6" "РЎРєР°С‡Р°С‚СЊ manage.sh (СЃРєСЂРёРїС‚ СѓРїСЂР°РІР»РµРЅРёСЏ)"
    menu_item "7" "РќР°СЃС‚СЂРѕРёС‚СЊ .env (BOT_TOKEN + ADMIN_CHAT_ID + DB_*)"
    menu_item "8" "РћС‚РєСЂС‹С‚СЊ manage.sh (СѓРїСЂР°РІР»РµРЅРёРµ Р±РѕС‚РѕРј)"
    menu_item "9" "Р’РєР»СЋС‡РёС‚СЊ Р°РІС‚Рѕ-РѕС‚РєСЂС‹С‚РёРµ manage.sh РїСЂРё SSH-РІС…РѕРґРµ"
    menu_item "10" "Р’С‹РєР»СЋС‡РёС‚СЊ Р°РІС‚Рѕ-РѕС‚РєСЂС‹С‚РёРµ manage.sh"
    menu_item "11" "РџРѕР»РЅРѕСЃС‚СЊСЋ СѓРґР°Р»РёС‚СЊ Р±РѕС‚Р° СЃ VDS"
    menu_item "0" "Р’С‹С…РѕРґ"

    printf "%bР’С‹Р±РµСЂРё РїСѓРЅРєС‚ [0-11]: %b" "$COLOR_YELLOW" "$COLOR_RESET"
    read -r choice
    choice="${choice//$'\r'/}"
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"
    if [[ -z "$choice" ]]; then
      continue
    fi

    case "$choice" in
      1) full_install ;;
      2) check_step ;;
      3) install_system_packages ;;
      4) install_python_deps; prepare_project_files ;;
      5) write_systemd_service ;;
      6) download_manage_script ;;
      7) setup_bot_identity ;;
      8) open_manage_script ;;
      9) enable_manage_autostart ;;
      10) disable_manage_autostart ;;
      11) purge_bot ;;
      0) exit 0 ;;
      *)
        printf "%bРќРµРІРµСЂРЅС‹Р№ РІС‹Р±РѕСЂ. Р’РІРµРґРё С‡РёСЃР»Рѕ РѕС‚ 0 РґРѕ 11.%b\n" "$COLOR_RED" "$COLOR_RESET"
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
    full|all|РїРѕР»РЅР°СЏ)
      full_install
      ;;
    env|setup|РѕРєСЂСѓР¶РµРЅРёРµ)
      setup_bot_identity
      ;;
    check|РїСЂРѕРІРµСЂРєР°)
      check_step
      ;;
    components|component|РєРѕРјРїРѕРЅРµРЅС‚С‹)
      install_system_packages
      ;;
    python|venv|РїРёС‚РѕРЅ)
      install_python_deps
      prepare_project_files
      ;;
    service|СЃРµСЂРІРёСЃ)
      write_systemd_service
      ;;
    manage|manager|СѓРїСЂР°РІР»РµРЅРёРµ)
      download_manage_script "${2:-}"
      ;;
    open|run-manage|РѕС‚РєСЂС‹С‚СЊ)
      open_manage_script
      ;;
    auto-on|automanage-on|Р°РІС‚Рѕ-РІРєР»)
      enable_manage_autostart
      ;;
    auto-off|automanage-off|Р°РІС‚Рѕ-РІС‹РєР»)
      disable_manage_autostart
      ;;
    purge|remove|СѓРґР°Р»РёС‚СЊ)
      purge_bot
      ;;
    -h|--help|help|РїРѕРјРѕС‰СЊ)
      usage
      ;;
    *)
      echo "РќРµРёР·РІРµСЃС‚РЅР°СЏ РєРѕРјР°РЅРґР°: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
