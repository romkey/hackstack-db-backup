FROM alpine:latest

# Install dependencies
RUN apk update && apk upgrade && \
    apk add --no-cache \
    build-base \
    curl \
    git \
    libffi-dev \
    openssl-dev \
    readline-dev \
    sqlite-dev \
    zlib-dev \
    mariadb-client \
    postgresql-client \
    sqlite \
    redis \
    bzip2 \
    bash \
    tzdata

# Install Ruby
RUN apk add --no-cache ruby ruby-dev && \
    gem update --system && \
    gem install bundler

# Clean up
RUN rm -rf /var/cache/apk/* /tmp/* /usr/lib/ruby/gems/*/cache/*

# Create a directory for the app
WORKDIR /app

# Copy the Ruby script into the container
COPY backup.rb /app/

# Make the script executable
RUN chmod +x /app/backup.rb

# Set the entrypoint to the Ruby script
ENTRYPOINT ["ruby", "/app/backup.rb"]

# This will allow you to pass any additional arguments to the script
CMD []
