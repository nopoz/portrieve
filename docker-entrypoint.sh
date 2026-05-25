#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for the containerized tool.
#
#   docker run ... IMAGE export            one-shot export (default)
#   docker run ... IMAGE import --source … one-shot import
#   docker run -e SCHEDULE="0 3 * * *" …   run the command on a cron schedule
#
# Credentials come from PORTAINER_URL / PORTAINER_API_KEY (or a mounted
# .portainer_config). The backup directory defaults to /backup.

# Default to a one-shot export when no command is given.
if [[ $# -eq 0 ]]; then
	set -- export
fi

# One-shot mode: run the command and exit with its status.
if [[ -z "${SCHEDULE:-}" ]]; then
	exec /app/portrieve.sh "$@"
fi

# Scheduled mode: run the command on a cron schedule via busybox crond.
echo "[entrypoint] scheduled mode: '$*' at cron '${SCHEDULE}' (TZ=${TZ:-UTC})"

if [[ "${RUN_ON_START:-true}" == "true" ]]; then
	echo "[entrypoint] initial run on startup"
	/app/portrieve.sh "$@" || echo "[entrypoint] startup run failed; will retry on schedule"
fi

# crond becomes PID 1 after exec, so /proc/1/fd/{1,2} is the container's
# stdout/stderr and scheduled-run output shows up in `docker logs`.
echo "${SCHEDULE} /app/portrieve.sh $* > /proc/1/fd/1 2> /proc/1/fd/2" | crontab -
echo "[entrypoint] starting crond"
exec crond -f -l 8
