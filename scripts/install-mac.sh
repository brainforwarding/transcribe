#!/bin/bash
# Public Mac binary installer. No credentials, sudo, permission grants or source builds.
set -euo pipefail

verify_transcribe_app() {
    local app="$1"
    local requirement='anchor apple generic and identifier "com.sebastianmarambio.transcribe" and certificate leaf[subject.OU] = "K542ZFQH6B" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    codesign --verify --deep --strict --test-requirement "=$requirement" "$app"
    [ "$(defaults read "$app/Contents/Info" CFBundleShortVersionString)" = "2.1.0" ] || { echo 'Unexpected app version.' >&2; return 1; }
    spctl --assess --type execute "$app"
}

install_transcribe() (
    set -euo pipefail
    umask 077
    user_directory="$1"
    system_applications="${2:-/Applications}"
    applications="$user_directory/Applications"
    destination="$applications/Transcribe.app"
    release='https://github.com/brainforwarding/transcribe/releases/download/v2.1.0/Transcribe.dmg'
    digest='2683c0c38f62fd510f86eb62df9aad92a03e865c9a7e42794d50c661d16aafcb'
    workspace='' staging=''

    cleanup_install() {
        local result=$?
        trap - EXIT INT TERM
        # Inspect mount evidence, including a partial attachment interrupted before return.
        if [ -n "$workspace" ] && mount | grep -Fq " on $workspace/mount ("; then
            if ! hdiutil detach "$workspace/mount" -quiet; then
                echo "Could not unmount $workspace/mount. Eject it in Finder. Temporary files were preserved." >&2
                workspace=''
                result=1
            fi
        fi
        [ -z "$staging" ] || rm -r -- "$staging"
        [ -z "$workspace" ] || rm -r -- "$workspace"
        exit "$result"
    }
    trap cleanup_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo 'Transcribe requires an Apple Silicon Mac.' >&2; exit 1; }
    system_version=$(sw_vers -productVersion)
    [ "${system_version%%.*}" -ge 13 ] || { echo 'Transcribe requires macOS 13 or later.' >&2; exit 1; }
    for existing in "$system_applications/Transcribe.app" "$destination"; do
        if [ -e "$existing" ] || [ -L "$existing" ]; then
            echo "Transcribe already exists at $existing. Open that copy and use its in-app update." >&2
            exit 1
        fi
    done
    [ ! -L "$applications" ] || { echo 'Applications is a symlink. Install the disk image manually.' >&2; exit 1; }
    mkdir -p "$applications"
    [ -d "$applications" ] && [ -w "$applications" ] || { echo 'Your Applications folder is not writable.' >&2; exit 1; }
    workspace=$(mktemp -d "${TMPDIR:-/tmp}/transcribe-download.XXXXXX")
    staging=$(mktemp -d "$applications/.transcribe-install.XXXXXX")
    echo 'Downloading Transcribe 2.1.0…'
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 180 "$release" -o "$workspace/Transcribe.dmg"
    actual_digest=$(shasum -a 256 "$workspace/Transcribe.dmg")
    [ "${actual_digest%% *}" = "$digest" ] || { echo 'Download checksum did not match. Nothing was installed.' >&2; exit 1; }
    mkdir "$workspace/mount"
    hdiutil attach "$workspace/Transcribe.dmg" -readonly -nobrowse -mountpoint "$workspace/mount" -quiet
    verify_transcribe_app "$workspace/mount/Transcribe.app"
    ditto "$workspace/mount/Transcribe.app" "$staging/Transcribe.app"
    verify_transcribe_app "$staging/Transcribe.app"
    hdiutil detach "$workspace/mount" -quiet
    [ ! -L "$applications" ] || { echo 'Applications changed during installation.' >&2; exit 1; }
    for existing in "$system_applications/Transcribe.app" "$destination"; do
        [ ! -e "$existing" ] && [ ! -L "$existing" ] || { echo "An app appeared at $existing. Nothing was replaced." >&2; exit 1; }
    done
    # BSD mv -n into the parent refuses a competing destination, including symlinks.
    mv -n "$staging/Transcribe.app" "$applications/"
    [ ! -e "$staging/Transcribe.app" ] || { echo 'Another installation appeared. Nothing was replaced.' >&2; exit 1; }
    printf 'Installed at %s\nOpen it to finish connection and permission setup:\n  open %q\n' "$destination" "$destination"
)

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    install_transcribe "$HOME"
fi
