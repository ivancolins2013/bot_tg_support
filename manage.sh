#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-support-bot}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR_GREEN=$'\033[32m'
  COLOR_RED=$'\033[31m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_GREEN=""
  COLOR_RED=""
  COLOR_RESET=""
fi

usage() {
  cat <<'EOF'
Использование:
  ./manage.sh                 # интерактивное меню
  ./manage.sh start
  ./manage.sh stop
  ./manage.sh restart
  ./manage.sh status
  ./manage.sh logs [N]
  ./manage.sh live
  ./manage.sh enable
  ./manage.sh disable
  ./manage.sh install
  ./manage.sh help

Русские алиасы:
  ./manage.sh старт
  ./manage.sh стоп
  ./manage.sh перезапуск
  ./manage.sh статус
  ./manage.sh логи [N]
  ./manage.sh консоль
  ./manage.sh включить
  ./manage.sh выключить
  ./manage.sh инстал
  ./manage.sh помощь

Параметры:
  logs [N]   Показать последние N строк логов (по умолчанию: 100) и продолжить вывод.
  live       Консоль в реальном времени (journalctl -f).

Переменные окружения:
  SERVICE_NAME   Переопределить имя systemd-сервиса (по умолчанию: support-bot)
EOF
}

colorize_state() {
  local state="${1:-}"
  case "$state" in
    "запущен"|"включено")
      printf "%b%s%b" "$COLOR_GREEN" "$state" "$COLOR_RESET"
      ;;
    *)
      printf "%b%s%b" "$COLOR_RED" "$state" "$COLOR_RESET"
      ;;
  esac
}

autostart_state_text() {
  if systemctl is-enabled --quiet "$SERVICE_NAME"; then
    echo "включено"
  else
    echo "выключено"
  fi
}

service_state_text() {
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "запущен"
  else
    echo "остановлен"
  fi
}

interactive_menu() {
  while true; do
    local service_state
    local service_state_colored
    local autostart_state
    local autostart_state_colored
    service_state="$(service_state_text)"
    service_state_colored="$(colorize_state "$service_state")"
    autostart_state="$(autostart_state_text)"
    autostart_state_colored="$(colorize_state "$autostart_state")"

    cat <<EOF

===============================
Управление ботом (systemd)
===============================
1) Запустить бота (сейчас: ${service_state_colored})
2) Остановить бота
3) Перезапустить бота
4) Статус бота
5) Логи бота
6) Включить автозапуск (сейчас: ${autostart_state_colored})
7) Выключить автозапуск
8) Справка
9) Консоль в реальном времени
10) Открыть install.sh
0) Выход
EOF

    read -r -p "Выбери пункт [0-10]: " choice
    choice="${choice//$'\r'/}"
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"
    if [[ -z "$choice" ]]; then
      continue
    fi

    case "$choice" in
      1) start_service ;;
      2) stop_service ;;
      3) restart_service ;;
      4) status_service ;;
      5)
        read -r -p "Сколько строк логов показать? [100]: " lines
        show_logs_once_and_back "${lines:-100}"
        ;;
      6) enable_service ;;
      7) disable_service ;;
      8) usage ;;
      9) live_console_and_back ;;
      10) open_install_script ;;
      0) exit 0 ;;
      *)
        echo "Неверный выбор. Введи число от 0 до 10."
        ;;
    esac
  done
}

require_systemctl() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "Ошибка: systemctl недоступен на этом сервере."
    exit 1
  fi
}

start_service() {
  systemctl start "$SERVICE_NAME"
  systemctl status "$SERVICE_NAME" --no-pager
}

stop_service() {
  systemctl stop "$SERVICE_NAME"
  systemctl status "$SERVICE_NAME" --no-pager || true
}

restart_service() {
  systemctl restart "$SERVICE_NAME"
  systemctl status "$SERVICE_NAME" --no-pager
}

status_service() {
  if ! systemctl status "$SERVICE_NAME" --no-pager; then
    echo
    echo "Сервис '$SERVICE_NAME' сейчас не запущен или имеет ошибку."
  fi
}

logs_service() {
  local lines="${1:-100}"
  journalctl -u "$SERVICE_NAME" -n "$lines" -f || true
}

show_logs_once_and_back() {
  local lines="${1:-100}"
  journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager || true
  echo
  read -r -p "Нажми Enter, чтобы вернуться в меню..." _
}

live_console_and_back() {
  local logs_pid
  local interrupted=0

  echo
  echo "Открыт поток логов. Нажми Enter для возврата в меню (или Ctrl+C)."

  journalctl -u "$SERVICE_NAME" -f --no-pager &
  logs_pid=$!

  trap 'interrupted=1' INT
  while true; do
    if IFS= read -r -t 0.2 _; then
      break
    fi
    if [[ "$interrupted" -eq 1 ]]; then
      break
    fi
    if ! kill -0 "$logs_pid" 2>/dev/null; then
      break
    fi
  done
  trap - INT

  kill "$logs_pid" 2>/dev/null || true
  wait "$logs_pid" 2>/dev/null || true
}

enable_service() {
  systemctl enable "$SERVICE_NAME"
  systemctl is-enabled "$SERVICE_NAME"
}

disable_service() {
  systemctl disable "$SERVICE_NAME"
  systemctl is-enabled "$SERVICE_NAME" || true
}

open_install_script() {
  local install_path
  install_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/install.sh"

  if [[ ! -f "$install_path" ]]; then
    echo "install.sh не найден рядом с manage.sh."
    return
  fi

  chmod +x "$install_path"
  echo "Открываю меню установщика: $install_path"
  bash "$install_path"
}

main() {
  require_systemctl

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
    start|старт)
      start_service
      ;;
    stop|стоп)
      stop_service
      ;;
    restart|перезапуск)
      restart_service
      ;;
    status|статус)
      status_service
      ;;
    logs|логи)
      logs_service "${2:-100}"
      ;;
    live|консоль|console)
      journalctl -u "$SERVICE_NAME" -f --no-pager
      ;;
    enable|включить)
      enable_service
      ;;
    disable|выключить)
      disable_service
      ;;
    install|installer|инстал|установщик)
      open_install_script
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
