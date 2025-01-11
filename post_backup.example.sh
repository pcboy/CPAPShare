#!/usr/bin/env bash

send_notification() {
  local message="$1"
  local url="https://ntfy.sh/cpap-test"

  curl -s "$url" \
    -H "Title: CPAPShare" \
    -H "Priority: default" \
    -H "Tags: white_check_mark,backup" \
    -d "$message" >/dev/null
}

# Send the notification
send_notification "Backup completed successfully at $(date '+%Y-%m-%d %H:%M:%S')"
