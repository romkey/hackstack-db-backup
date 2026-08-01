FROM alpine:3.23

# Install only runtime dependencies - no build tools needed
RUN apk add --no-cache \
    ruby \
    mariadb-client \
    postgresql18-client \
    sqlite \
    bzip2 \
    age \
    tzdata \
    && rm -rf /var/cache/apk/* /tmp/*

WORKDIR /app

COPY app/backup.rb app/backup-crypt.rb /app/

RUN chmod +x /app/backup.rb /app/backup-crypt.rb

ENTRYPOINT ["ruby", "/app/backup.rb"]
CMD []
