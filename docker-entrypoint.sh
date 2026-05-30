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
#
# Set PUID/PGID to own the exported files: the container reconciles the backup
# tree to that user and drops privileges before running. Left unset, it runs as
# root (the previous behaviour).

BACKUP_DIR="${PORTAINER_BACKUP_DIR:-/backup}"

# Default to a one-shot export when no command is given.
if [[ $# -eq 0 ]]; then
	set -- export
fi

# When PUID/PGID are requested, normalise the existing backup tree (ownership
# and modes) so the unprivileged run can overwrite it, then build the su-exec
# prefix used to drop privileges. `>` truncates in place and keeps an existing
# file's owner/mode, and umask only affects newly created files, so a legacy
# root-owned 644 tree would otherwise break the export or stay world-readable.
run_prefix=()
if [[ -n "${PUID:-}" || -n "${PGID:-}" ]]; then
	: "${PUID:=0}"
	: "${PGID:=0}"

	if [[ -d "$BACKUP_DIR" ]]; then
		umask_val="${PORTAINER_BACKUP_UMASK:-077}"
		# Derive the modes the script's umask would produce for new files/dirs.
		dir_mode=$(printf '%03o' "$(( 0777 & ~0"$umask_val" ))")
		file_mode=$(printf '%03o' "$(( 0666 & ~0"$umask_val" ))")
		echo "[entrypoint] reconciling $BACKUP_DIR to ${PUID}:${PGID} (dirs $dir_mode, files $file_mode)"
		chown -R "$PUID:$PGID" "$BACKUP_DIR"
		find "$BACKUP_DIR" -type d -exec chmod "$dir_mode" {} +
		find "$BACKUP_DIR" -type f -exec chmod "$file_mode" {} +
	fi

	run_prefix=(su-exec "$PUID:$PGID")
fi

# One-shot mode: run the command and exit with its status.
if [[ -z "${SCHEDULE:-}" ]]; then
	exec "${run_prefix[@]}" /app/portrieve.sh "$@"
fi

# Scheduled mode: run the command on a cron schedule via busybox crond.
echo "[entrypoint] scheduled mode: '$*' at cron '${SCHEDULE}' (TZ=${TZ:-UTC})"

if [[ "${RUN_ON_START:-true}" == "true" ]]; then
	echo "[entrypoint] initial run on startup"
	"${run_prefix[@]}" /app/portrieve.sh "$@" || echo "[entrypoint] startup run failed; will retry on schedule"
fi

# crond becomes PID 1 after exec, so /proc/1/fd/{1,2} is the container's
# stdout/stderr and scheduled-run output shows up in `docker logs`. crond itself
# stays root; the job drops to PUID/PGID via the same su-exec prefix.
echo "${SCHEDULE} ${run_prefix[*]:+${run_prefix[*]} }/app/portrieve.sh $* > /proc/1/fd/1 2> /proc/1/fd/2" | crontab -
echo "[entrypoint] starting crond"
exec crond -f -l 8
