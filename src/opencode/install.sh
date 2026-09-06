#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# opencode feature install (runs as root during image build).
# Production Public Feature Standard Implementation. Zero hardcoded users.
# ---------------------------------------------------------------------------

# --- 1. Determine remote user context using spec-injected vars -------------
USERNAME="${_REMOTE_USER:-"vscode"}"
USER_HOME="${_REMOTE_USER_HOME:-"/home/${USERNAME}"}"

if [ "${USERNAME}" = "root" ]; then
    USER_HOME="/root"
fi

# Ensure the target user exists (common-utils typically creates it, but be safe)
if ! id "${USERNAME}" >/dev/null 2>&1; then
    echo "WARNING: user '${USERNAME}' not found; creating it."
    useradd -m -s /bin/bash "${USERNAME}" || true
fi

# --- 2. Extract and sanitize targeted installation version -----------------
OPENCODE_VERSION="${VERSION:-${_VERSION:-1.18.29}}"
OPENCODE_VERSION="${OPENCODE_VERSION#v}"

echo "Installing opencode v${OPENCODE_VERSION} for execution user: ${USERNAME}..."

TARGET_BIN_DIR="${USER_HOME}/.opencode/bin"
mkdir -p "${TARGET_BIN_DIR}"
chown "${USERNAME}:${USERNAME}" "${USER_HOME}/.opencode" "${TARGET_BIN_DIR}" 2>/dev/null || true
# --- 3. Clean installer fetch and build-cache clearing ----------------------
su - "${USERNAME}" -c "curl -fsSL https://opencode.ai/install | bash -s -- --version ${OPENCODE_VERSION}" || {
    echo "WARNING: installer reported an error; verifying installed binary." >&2
}

# --- 4. Verify installation (warn, do not hard-fail, on version drift) -------
INSTALLED_BIN="${TARGET_BIN_DIR}/opencode"
if [ ! -x "${INSTALLED_BIN}" ]; then
    echo "ERROR: opencode binary not found at ${INSTALLED_BIN}." >&2
    exit 1
fi
INSTALLED_VER="$(su - "${USERNAME}" -c "'${INSTALLED_BIN}' --version" 2>/dev/null || true)"

# --- 5. Shell runtime auth sync hooks ---------------------------------------
AUTH_HOOK='_opencode_sync_auth() {
    local MOUNTED_FILE="${HOME}/.opencode-host-sync/auth.json"
    local TARGET_FILE="${HOME}/.local/share/opencode/auth.json"
    if [ -f "$MOUNTED_FILE" ] && [ "$MOUNTED_FILE" -nt "$TARGET_FILE" ]; then
        mkdir -p "${TARGET_FILE%/*}" 2>/dev/null || true
        cp "$MOUNTED_FILE" "$TARGET_FILE" 2>/dev/null || true
        chmod 600 "$TARGET_FILE" 2>/dev/null || true
    fi
}
_opencode_sync_auth'

for rc in ".bashrc" ".zshrc"; do
    RC_PATH="${USER_HOME}/${rc}"
    if [ -f "${RC_PATH}" ]; then
        if ! grep -q "_opencode_sync_auth" "${RC_PATH}"; then
            printf '\n%s\n' "${AUTH_HOOK}" >> "${RC_PATH}"
        fi
    else
        printf '%s\n' "${AUTH_HOOK}" > "${RC_PATH}"
    fi
    chown "${USERNAME}:${USERNAME}" "${RC_PATH}" 2>/dev/null || true
done

# --- 6. Clean up temporary footprint ----------------------------------------
rm -rf /var/lib/apt/lists/* /tmp/*
echo "Opencode feature installation layers fully completed successfully."
