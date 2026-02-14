# PlexBeam Plex + Cartridge — Docker Image
# Based on linuxserver/plex with the cartridge pre-installed.
# The cartridge intercepts transcode requests and dispatches them
# to a remote GPU worker via HTTP API.
#
# Build:  docker build -t plexbeam-plex ./cartridge
# Run:    docker run -e PLEXBEAM_WORKER_URL=http://worker:8765 ... plexbeam-plex

FROM lscr.io/linuxserver/plex:latest

LABEL maintainer="PlexBeam"
LABEL description="Plex Media Server with PlexBeam cartridge for remote GPU transcoding"

# Install dependencies:
#   jq       - needed by cartridge for JSON serialization in raw_args
#   file     - needed by init/watchdog to detect ELF binaries vs shell scripts
#   binutils - provides 'strings', needed for Plex version detection from binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    file \
    binutils \
    && rm -rf /var/lib/apt/lists/*

# Copy all cartridge scripts to permanent home
COPY cartridge.sh analyze.sh install.sh uninstall.sh watchdog.sh \
     /opt/plex-cartridge/

# Preserve pristine template (before any baking)
RUN cp /opt/plex-cartridge/cartridge.sh /opt/plex-cartridge/cartridge.sh.orig

# Make all scripts executable
RUN chmod +x /opt/plex-cartridge/*.sh

# Install init script (runs before Plex starts)
COPY docker-init.sh /custom-cont-init.d/50-plexbeam-cartridge
RUN chmod +x /custom-cont-init.d/50-plexbeam-cartridge

# Install watchdog as S6 v3 (s6-rc) longrun service
RUN mkdir -p /etc/s6-overlay/s6-rc.d/svc-plexbeam-watchdog/dependencies.d && \
    echo "longrun" > /etc/s6-overlay/s6-rc.d/svc-plexbeam-watchdog/type && \
    touch /etc/s6-overlay/s6-rc.d/svc-plexbeam-watchdog/dependencies.d/init-services && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/svc-plexbeam-watchdog
COPY docker-watchdog.sh /etc/s6-overlay/s6-rc.d/svc-plexbeam-watchdog/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/svc-plexbeam-watchdog/run

# Create log directory structure
RUN mkdir -p /var/log/plex-cartridge/sessions

# PlexBeam environment variables (override at runtime)
ENV PLEXBEAM_WORKER_URL="" \
    PLEXBEAM_API_KEY="" \
    PLEXBEAM_SHARED_SEGMENT_DIR="" \
    PLEXBEAM_UPDATE_REPO="local" \
    PLEXBEAM_CALLBACK_URL="" \
    PLEXBEAM_WORKER_POOL=""
