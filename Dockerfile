FROM alpine:3.21.3

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    base64 \
    jq \
    docker \
    iptables \
    openssl \
    ca-certificates \
    sudo

# Create pipe directory
WORKDIR /app

# Copy the scripts directory
COPY scripts /app/scripts

# Copy the pipe scripts
COPY setup.sh /app

# Copy cleanup script
COPY cleanup.sh /app

# Make all scripts executable
RUN chmod +x setup.sh cleanup.sh scripts/*.sh 

# Set the entrypoint
ENTRYPOINT ["/app/setup.sh"]