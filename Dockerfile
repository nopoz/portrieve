FROM alpine:3.24

# bash for the scripts, curl/jq for the API, yq (mikefarah, from the community
# repo) for compose parsing, tzdata so cron schedules honour TZ, su-exec to drop
# privileges to PUID/PGID for backup ownership.
RUN apk add --no-cache bash curl jq yq tzdata ca-certificates su-exec

COPY portrieve.sh /app/portrieve.sh
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/portrieve.sh /app/docker-entrypoint.sh

# Backups land here; mount a volume to persist them.
ENV PORTAINER_BACKUP_DIR=/backup
WORKDIR /backup
VOLUME /backup

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["export"]
