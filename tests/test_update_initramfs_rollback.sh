#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRAPPER="${REPO_ROOT}/usr/local/sbin/dracut"
VALIDATOR="${REPO_ROOT}/usr/local/libexec/exordos-validate-initramfs"
UPDATE_INITRAMFS=${UPDATE_INITRAMFS:-/usr/sbin/update-initramfs}
TMP_DIR=$(mktemp -d)

cleanup() {
    find -P "$TMP_DIR" -xdev -depth -delete
}
trap cleanup EXIT

if [[ ! -x "$UPDATE_INITRAMFS" ]] ||
    ! grep -q 'dracut.*--force' "$UPDATE_INITRAMFS"; then
    echo "dracut-backed update-initramfs is required" >&2
    exit 1
fi

mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/boot"
ln -s "$WRAPPER" "${TMP_DIR}/bin/dracut"
printf 'last-known-good initramfs\n' >"${TMP_DIR}/boot/initrd.img-test-exordos"

cat >"${TMP_DIR}/bin/dracut-real" <<'EOF'
#!/bin/sh
set -eu

candidate=
cluster_seen=false
for argument in "$@"; do
    case "$argument" in
        "${FAKE_DRACUT_EXPECT_CLUSTER:-}") cluster_seen=true ;;
        *.exordos.*) candidate=$argument ;;
    esac
done
: "${candidate:?missing candidate path}"
: "${FAKE_DRACUT_MARKER:?missing invocation marker}"
: >"$FAKE_DRACUT_MARKER"
[ -z "${FAKE_DRACUT_EXPECT_CLUSTER:-}" ] || [ "$cluster_seen" = true ]
printf 'damaged initramfs\n' >"$candidate"
[ "${FAKE_DRACUT_MODE:-fail}" = corrupt-success ] && exit 0
exit 42
EOF
chmod +x "${TMP_DIR}/bin/dracut-real"

cat >"${TMP_DIR}/bin/dracut-rebuild" <<'EOF'
#!/bin/sh
set -eu

candidate=
force=false
rebuild_source=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --rebuild)
            shift
            rebuild_source=$1
            ;;
        --rebuild=*) rebuild_source=${1#--rebuild=} ;;
        -f | --force | -*f*) force=true ;;
        *.exordos.*) candidate=$1 ;;
    esac
    shift
done
: "${candidate:?missing rebuild candidate path}"
: "${rebuild_source:?missing rebuild source path}"
: "${FAKE_DRACUT_EXPECT_SOURCE:?missing expected rebuild source}"
: "${FAKE_DRACUT_MARKER:?missing invocation marker}"
[ "$rebuild_source" = "$FAKE_DRACUT_EXPECT_SOURCE" ]
[ "$candidate" != "$rebuild_source" ]
[ -e "$rebuild_source" ]
: >"$FAKE_DRACUT_MARKER"
if [ -e "$candidate" ] && [ "$force" = false ]; then
    exit 17
fi
printf 'damaged rebuilt initramfs\n' >"$candidate"
exit 42
EOF
chmod +x "${TMP_DIR}/bin/dracut-rebuild"

assert_no_force_refusal() {
    local before after marker status

    before=$(sha256sum "${TMP_DIR}/boot/initrd.img-test-exordos")
    marker="${TMP_DIR}/dracut-no-force.called"

    cat >"${TMP_DIR}/bin/dracut-refuse-existing" <<'EOF'
#!/bin/sh
set -eu

force=false
target=
for argument in "$@"; do
    case "$argument" in
        -f | --force) force=true ;;
        *.exordos.*) target=$argument ;;
        initrd.img-* | */initrd.img-*) target=$argument ;;
    esac
done
: "${target:?missing output path}"
: "${FAKE_DRACUT_MARKER:?missing invocation marker}"
: >"$FAKE_DRACUT_MARKER"
if [ "$force" = false ] && [ -e "$target" ]; then
    exit 17
fi
exit 99
EOF
    chmod +x "${TMP_DIR}/bin/dracut-refuse-existing"

    set +e
    EXORDOS_DRACUT_REAL="${TMP_DIR}/bin/dracut-refuse-existing" \
        EXORDOS_INITRAMFS_VALIDATOR="$VALIDATOR" \
        FAKE_DRACUT_MARKER="$marker" \
        "$WRAPPER" "${TMP_DIR}/boot/initrd.img-test-exordos" \
        >/dev/null 2>&1
    status=$?
    set -e
    if ((status != 17)); then
        echo "dracut wrapper returned ${status}, expected no-force refusal 17" >&2
        exit 1
    fi
    [[ -e "$marker" ]]
    after=$(sha256sum "${TMP_DIR}/boot/initrd.img-test-exordos")
    [[ "$before" == "$after" ]]
    if find "${TMP_DIR}/boot" -maxdepth 1 -name '*.exordos.*' -print -quit |
        grep -q .; then
        echo "no-force invocation left a candidate initramfs" >&2
        exit 1
    fi
}

assert_clustered_force_rollback() {
    local before after marker status

    before=$(sha256sum "${TMP_DIR}/boot/initrd.img-test-exordos")
    marker="${TMP_DIR}/dracut-clustered-force.called"

    set +e
    EXORDOS_DRACUT_REAL="${TMP_DIR}/bin/dracut-real" \
        EXORDOS_INITRAMFS_VALIDATOR="$VALIDATOR" \
        FAKE_DRACUT_EXPECT_CLUSTER=-fv \
        FAKE_DRACUT_MODE=fail \
        FAKE_DRACUT_MARKER="$marker" \
        "$WRAPPER" -fv "${TMP_DIR}/boot/initrd.img-test-exordos" \
        >/dev/null 2>&1
    status=$?
    set -e
    if ((status != 42)); then
        echo "clustered-force wrapper returned ${status}, expected 42" >&2
        exit 1
    fi
    [[ -e "$marker" ]]
    after=$(sha256sum "${TMP_DIR}/boot/initrd.img-test-exordos")
    [[ "$before" == "$after" ]]
    if find "${TMP_DIR}/boot" -maxdepth 1 -name '*.exordos.*' -print -quit |
        grep -q .; then
        echo "clustered-force invocation left a candidate initramfs" >&2
        exit 1
    fi
}

assert_symlink_target_publish() {
    local link marker versioned

    versioned="${TMP_DIR}/boot/initrd.img-symlink-versioned"
    link="${TMP_DIR}/boot/initrd.img-symlink"
    marker="${TMP_DIR}/dracut-symlink.called"
    printf 'versioned initramfs\n' >"$versioned"
    ln -s "${versioned##*/}" "$link"

    EXORDOS_DRACUT_REAL="${TMP_DIR}/bin/dracut-real" \
        EXORDOS_INITRAMFS_VALIDATOR=/bin/true \
        FAKE_DRACUT_MODE=corrupt-success \
        FAKE_DRACUT_MARKER="$marker" \
        "$WRAPPER" -f "$link" >/dev/null 2>&1

    [[ -e "$marker" ]]
    [[ -L "$link" ]]
    [[ "$(readlink "$link")" == "${versioned##*/}" ]]
    grep -Fx 'damaged initramfs' "$versioned" >/dev/null
    if find "${TMP_DIR}/boot" -maxdepth 1 -name '*.exordos.*' -print -quit |
        grep -q .; then
        echo "symlink invocation left a candidate initramfs" >&2
        exit 1
    fi
}

assert_rebuild_rollback() {
    local form=$1
    local source target source_before target_before source_after target_after
    local marker status

    source="${TMP_DIR}/boot/initrd.img-rebuild-source-${form}"
    target=$source
    printf 'rebuild source %s\n' "$form" >"$source"
    if [[ "$form" == explicit ]]; then
        target="${TMP_DIR}/boot/initrd.img-rebuild-output-${form}"
        printf 'published rebuild output %s\n' "$form" >"$target"
    fi
    source_before=$(sha256sum "$source")
    target_before=$(sha256sum "$target")
    marker="${TMP_DIR}/dracut-rebuild-${form}.called"

    set +e
    case "$form" in
        implicit)
            EXORDOS_DRACUT_REAL="${TMP_DIR}/bin/dracut-rebuild" \
                EXORDOS_INITRAMFS_VALIDATOR="$VALIDATOR" \
                FAKE_DRACUT_EXPECT_SOURCE="$source" \
                FAKE_DRACUT_MARKER="$marker" \
                "$WRAPPER" --rebuild "$source" >/dev/null 2>&1
            status=$?
            ;;
        equals)
            EXORDOS_DRACUT_REAL="${TMP_DIR}/bin/dracut-rebuild" \
                EXORDOS_INITRAMFS_VALIDATOR="$VALIDATOR" \
                FAKE_DRACUT_EXPECT_SOURCE="$source" \
                FAKE_DRACUT_MARKER="$marker" \
                "$WRAPPER" "--rebuild=$source" >/dev/null 2>&1
            status=$?
            ;;
        explicit)
            EXORDOS_DRACUT_REAL="${TMP_DIR}/bin/dracut-rebuild" \
                EXORDOS_INITRAMFS_VALIDATOR="$VALIDATOR" \
                FAKE_DRACUT_EXPECT_SOURCE="$source" \
                FAKE_DRACUT_MARKER="$marker" \
                "$WRAPPER" -f "$target" --rebuild "$source" >/dev/null 2>&1
            status=$?
            ;;
        *) return 2 ;;
    esac
    set -e
    if ((status != 42)); then
        echo "${form} rebuild returned ${status}, expected 42" >&2
        exit 1
    fi
    [[ -e "$marker" ]]
    source_after=$(sha256sum "$source")
    target_after=$(sha256sum "$target")
    [[ "$source_before" == "$source_after" ]]
    [[ "$target_before" == "$target_after" ]]
    if find "${TMP_DIR}/boot" -maxdepth 1 -name '*.exordos.*' -print -quit |
        grep -q .; then
        echo "${form} rebuild left a candidate initramfs" >&2
        exit 1
    fi
}

assert_rollback() {
    local mode=$1
    local before after expected_status marker status

    before=$(sha256sum "${TMP_DIR}/boot/initrd.img-test-exordos")
    marker="${TMP_DIR}/dracut-${mode}.called"
    case "$mode" in
        fail) expected_status=42 ;;
        corrupt-success) expected_status=1 ;;
        *) return 2 ;;
    esac
    set +e
    PATH="${TMP_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        EXORDOS_DRACUT_REAL="${TMP_DIR}/bin/dracut-real" \
        EXORDOS_INITRAMFS_VALIDATOR="$VALIDATOR" \
        FAKE_DRACUT_MODE="$mode" \
        FAKE_DRACUT_MARKER="$marker" \
        "$UPDATE_INITRAMFS" -u -k test-exordos -b "${TMP_DIR}/boot" \
        >/dev/null 2>&1
    status=$?
    set -e
    if ((status != expected_status)); then
        echo "update-initramfs returned ${status}, expected ${expected_status} for ${mode}" >&2
        exit 1
    fi
    [[ -e "$marker" ]]
    after=$(sha256sum "${TMP_DIR}/boot/initrd.img-test-exordos")
    [[ "$before" == "$after" ]]
    [[ ! -e "${TMP_DIR}/boot/initrd.img-test-exordos.dpkg-bak" ]]
    if find "${TMP_DIR}/boot" -maxdepth 1 -name '*.exordos.*' -print -quit |
        grep -q .; then
        echo "candidate initramfs was not cleaned up" >&2
        exit 1
    fi
}

assert_no_force_refusal
assert_clustered_force_rollback
assert_symlink_target_publish
assert_rebuild_rollback implicit
assert_rebuild_rollback equals
assert_rebuild_rollback explicit
assert_rollback fail
assert_rollback corrupt-success
