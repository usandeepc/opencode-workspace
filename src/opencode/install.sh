#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# opencode feature install (runs as root during image build, devcontainers
# convention). Installs a PINNED opencode CLI and adds an auth-sync shell
# hook. NO secrets are written to the image; auth is runtime-only.
# ---------------------------------------------------------------------------

# --- 1. Resolve the non-root remote user (devcontainers convention) ---------
if [ -n "${_REMOTE_USER:-}" ]; then
    USERNAME="${_REMOTE_USER}"
    USER_HOME="${_REMOTE_USER_HOME:-/home/${USERNAME}}"
elif [ -n "${USER:-}" ] && [ "${USER}" != "root" ]; then
    USERNAME="${USER}"
    USER_HOME="$(getent passwd "${USERNAME}" | cut -d: -f6)"
else
    USERNAME="vscode"
    USER_HOME="/home/${USERNAME}"
fi
if [ "${USERNAME}" = "root" ]; then
    USER_HOME="/root"
fi

# --- 2. Version: feature option -> env (default pinned) ---------------------
OPENCODE_VERSION="${VERSION:-${_VERSION:-1.18.29}}"
OPENCODE_VERSION="${OPENCODE_VERSION#v}"   # tolerate "v1.18.29" input

# --- 3. Install opencode (pinned). Installer self-handles matching installs --
CURRENT_VERSION="$(su - "${USERNAME}" -c 'command -v opencode >/dev/null 2>&1 && opencode --version' 2>/dev/null || true)"
if [ -n "${CURRENT_VERSION}" ] && [ "${CURRENT_VERSION}" = "${OPENCODE_VERSION}" ]; then
    echo "opencode ${OPENCODE_VERSION} already installed for ${USERNAME}; skipping."
else
    echo "Installing opencode ${OPENCODE_VERSION} for ${USERNAME}..."
    su - "${USERNAME}" -c "curl -fsSL https://opencode.ai/install | bash -s -- --version ${OPENCODE_VERSION}"
    INSTALLED="$(su - "${USERNAME}" -c 'opencode --version' 2>/dev/null || true)"
    if [ "${INSTALLED}" != "${OPENCODE_VERSION}" ]; then
        echo "ERROR: expected opencode ${OPENCODE_VERSION}, got '${INSTALLED}'" >&2
        exit 1
    fi
fi

# --- 4. Auth-sync shell hook (host file is source of truth at shell start) --
AUTH_HOOK='_opencode_sync_auth() {
    local MOUNTED_FILE="/mnt/opencode-auth.json"
    local TARGET_FILE="${HOME}/.local/share/opencode/auth.json"
    if [ -f "$MOUNTED_FILE" ] && [ "$MOUNTED_FILE" -nt "$TARGET_FILE" ]; then
        mkdir -p "${TARGET_FILE%/*}" 2>/dev/null || true
        cp "$MOUNTED_FILE" "$TARGET_FILE" 2>/dev/null || true
        chmod 600 "$TARGET_FILE" 2>/dev/null || true
    fi
}
_opencode_sync_auth'

for rc in ".bashrc" ".zshrc"; do
    RC_FILE="${USER_HOME}/${rc}"
    if [ -f "${RC_FILE}" ]; then
        if ! grep -q "_opencode_sync_auth" "${RC_FILE}"; then
            printf '\n%s\n' "${AUTH_HOOK}" >> "${RC_FILE}"
        fi
    else
        printf '%s\n' "${AUTH_HOOK}" > "${RC_FILE}"
    fi
    chown "${USERNAME}" "${RC_FILE}" 2>/dev/null || true
done

echo "opencode-workspace feature complete: opencode ${OPENCODE_VERSION} + auth sync hook"
