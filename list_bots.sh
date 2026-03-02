#!/usr/bin/env bash

set -euo pipefail

if ! command -v systemctl >/dev/null 2>&1; then
  echo "Ошибка: systemctl недоступен на этом сервере."
  exit 1
fi

printf "%-28s %-9s %-9s %-24s %s\n" "SERVICE" "ACTIVE" "ENABLED" "PROJECT_NAME" "PATH"
printf "%-28s %-9s %-9s %-24s %s\n" "-------" "------" "-------" "------------" "----"

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

  printf "%-28s %-9s %-9s %-24s %s\n" "$service" "$active" "$enabled" "$project_name" "$workdir"
done
