#!/bin/sh

# Tulpar has no logind to make the runtime directory Wayland and D-Bus need.
if [ -z "$XDG_RUNTIME_DIR" ]; then
  XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
  mkdir -p -m 700 "$XDG_RUNTIME_DIR" 2>/dev/null
  export XDG_RUNTIME_DIR
fi
