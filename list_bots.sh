#!/usr/bin/env bash

set -euo pipefail

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Ошибка: systemctl недоступен на этом сервере."
  exit 1
fi

services=()
actives=()
enableds=()
project_names=()
workdirs=()

mapfile -t units < <(systemctl list-unit-files --type=service --no-legend | awk '{print $1}')

for unit in "${units[@]}"; do
  [[ "$unit" == *.service ]] || continue
  exec_start="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)"
  if [[ "$exec_start" != *"bot.py"* ]]; then
    continue
  fi

  service="${unit%.service}"
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  workdir="$(systemctl show "$unit" -p WorkingDirectory --value 2>/dev/null || true)"

  project_name="-"
  if [[ -n "$workdir" && -f "$workdir/.env" ]]; then
    project_name="$(grep -E '^PROJECT_NAME=' "$workdir/.env" | head -n 1 | cut -d= -f2-)"
    if [[ -z "$project_name" ]]; then
      project_name="-"
    fi
  fi

  services+=("$service")
  actives+=("$active")
  enableds+=("$enabled")
  project_names+=("$project_name")
  workdirs+=("$workdir")
done

if [[ "${#services[@]}" -eq 0 ]]; then
  echo "Боты не найдены."
  exit 0
fi

printf "%-3s %-28s %-9s %-9s %-24s %s\n" "№" "SERVICE" "ACTIVE" "ENABLED" "PROJECT_NAME" "PATH"
printf "%-3s %-28s %-9s %-9s %-24s %s\n" "---" "-------" "------" "-------" "------------" "----"

for i in "${!services[@]}"; do
  idx="$((i + 1))"
  printf "%-3s %-28s %-9s %-9s %-24s %s\n" "$idx" "${services[$i]}" "${actives[$i]}" "${enableds[$i]}" "${project_names[$i]}" "${workdirs[$i]}"
done

while true; do
  echo
  read -r -p "Выберите номер бота для управления (Enter - выход): " choice
  if [[ -z "${choice:-}" ]]; then
    exit 0
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "Неверный выбор: введите номер из списка."
    continue
  fi
  if (( choice < 1 || choice > ${#services[@]} )); then
    echo "Неверный выбор: введите номер из списка."
    continue
  fi

  i="$((choice - 1))"
  service="${services[$i]}"
  workdir="${workdirs[$i]}"

  if [[ -z "$workdir" || ! -d "$workdir" ]]; then
    echo "Каталог не найден: $workdir"
    continue
  fi

  echo
  echo "Выбран бот: $service"
  echo "1) Открыть manage.sh"
  echo "2) Открыть shell в каталоге"
  echo "3) Логи (journalctl -u ${service}.service -f)"
  echo "0) Назад"
  read -r -p "Выбор [0-3]: " action

  case "${action:-}" in
    1)
      if [[ -x "$workdir/manage.sh" ]]; then
        (cd "$workdir" && SERVICE_NAME="$service" bash ./manage.sh)
      elif [[ -f "$workdir/manage.sh" ]]; then
        echo "manage.sh найден, но без прав на запуск."
        read -r -p "Сделать исполняемым и открыть? [y/N]: " ans
        if [[ "${ans,,}" == "y" ]]; then
          chmod +x "$workdir/manage.sh"
          (cd "$workdir" && SERVICE_NAME="$service" bash ./manage.sh)
        fi
      else
        echo "manage.sh не найден в $workdir"
      fi
      ;;
    2)
      echo "Открываю shell в $workdir. Введите 'exit' чтобы вернуться."
      (cd "$workdir" && exec bash)
      ;;
    3)
      echo "Нажмите Ctrl+C для выхода из логов."
      journalctl -u "${service}.service" -f
      ;;
    0|"")
      ;;
    *)
      echo "Неверный выбор."
      ;;
  esac
done
