#!/usr/bin/with-contenv bash
# ============================================================================
# PlexBeam Cartridge — S6 Watchdog Service Wrapper
# ============================================================================
# Thin wrapper for /custom-services.d/. S6 manages restart/stop lifecycle.
# The watchdog monitors the Plex transcoder binary and re-installs the
# cartridge automatically after Plex updates.
# ============================================================================

exec /opt/plex-cartridge/watchdog.sh
