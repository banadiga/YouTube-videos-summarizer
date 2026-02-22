#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="yt_process"
TARGET_DIR="/usr/local/bin"
SOURCE="./yt_process.sh"

# ---- Preconditions ----

if [[ ! -f "$SOURCE" ]]; then
  echo "Error: $SCRIPT_NAME not found in current directory."
  echo "Place yt_process in this directory and retry."
  exit 1
fi

if [[ ! -r "$SOURCE" ]]; then
  echo "Error: $SCRIPT_NAME is not readable."
  exit 1
fi

echo "Checking Homebrew..."

if ! command -v brew >/dev/null 2>&1; then
  echo "Error: Homebrew not installed."
  echo "Install from: https://brew.sh/"
  exit 1
fi

# ---- Install dependencies if missing ----

install_if_missing() {
  local pkg="$1"
  if ! command -v "$pkg" >/dev/null 2>&1; then
    echo "Installing $pkg..."
    brew install "$pkg"
  else
    echo "$pkg already installed."
  fi
}

install_if_missing yt-dlp
install_if_missing jq
install_if_missing curl

# ---- Install script ----

DEST="$TARGET_DIR/$SCRIPT_NAME"

echo "Installing $SCRIPT_NAME to $DEST"

sudo mkdir -p "$TARGET_DIR"

# Copy atomically
TMP="$(mktemp)"
cp "$SOURCE" "$TMP"
chmod 755 "$TMP"

sudo mv -f "$TMP" "$DEST"
sudo chown root:wheel "$DEST"
sudo chmod 755 "$DEST"

echo "Installation complete."
