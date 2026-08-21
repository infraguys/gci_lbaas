#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOK="${REPO_ROOT}/etc/kernel/postinst.d/zz-exordos-validate-initramfs"
POST_UPDATE_HOOK="${REPO_ROOT}/etc/initramfs/post-update.d/00-exordos-validate-initramfs"
VALIDATOR="${REPO_ROOT}/usr/local/libexec/exordos-validate-initramfs"

TMP_DIR=$(mktemp -d)

cleanup() {
    rm -f \
        "${TMP_DIR}/bin/skipcpio" \
        "${TMP_DIR}/bin/lsinitrd" \
        "${TMP_DIR}/payload/init" \
        "${TMP_DIR}/early/early_cpio" \
        "${TMP_DIR}/boot/vmlinuz-test" \
        "${TMP_DIR}/boot/initrd.img-test" \
        "${TMP_DIR}/payload.cpio.zst" \
        "${TMP_DIR}/early.cpio"
    rmdir "${TMP_DIR}/bin" "${TMP_DIR}/payload" "${TMP_DIR}/early" \
        "${TMP_DIR}/boot" "${TMP_DIR}"
}

trap cleanup EXIT

mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/payload" "${TMP_DIR}/early" \
    "${TMP_DIR}/boot"
printf 'kernel\n' >"${TMP_DIR}/boot/vmlinuz-test"
printf '#!/bin/sh\n' >"${TMP_DIR}/payload/init"
printf '1\n' >"${TMP_DIR}/early/early_cpio"

(cd "${TMP_DIR}/payload" && find . -print | cpio --quiet -o -H newc) |
    zstd -q -1 -o "${TMP_DIR}/payload.cpio.zst"
(cd "${TMP_DIR}/early" && find . -print | cpio --quiet -o -H newc) \
    >"${TMP_DIR}/early.cpio"
early_size=$(stat -c %s "${TMP_DIR}/early.cpio")
if ((early_size % 512 != 0)); then
    echo "early CPIO fixture is not block-aligned" >&2
    exit 1
fi
early_blocks=$((early_size / 512))

cat >"${TMP_DIR}/bin/skipcpio" <<'EOF'
#!/bin/sh
set -eu
dd if="$1" bs=512 skip="${TEST_EARLY_BLOCKS:?}" status=none
EOF

cat >"${TMP_DIR}/bin/lsinitrd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
magic=$(dd if="$1" bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \n')
case "$magic" in
    303730373031 | 303730373032)
        "${DRACUT_SKIPCPIO:?}" "$1"
        ;;
    *)
        cat "$1"
        ;;
esac | zstd -q -d -c | cpio --quiet -t >/dev/null
EOF

chmod +x "${TMP_DIR}/bin/skipcpio" "${TMP_DIR}/bin/lsinitrd"

run_hook() {
    DRACUT_SKIPCPIO="${TMP_DIR}/bin/skipcpio" \
        EXORDOS_INITRAMFS_VALIDATOR="$VALIDATOR" \
        TEST_EARLY_BLOCKS="$early_blocks" \
        PATH="${TMP_DIR}/bin:${PATH}" \
        "$HOOK" test "${TMP_DIR}/boot/vmlinuz-test"
}

run_post_update_hook() {
    DRACUT_SKIPCPIO="${TMP_DIR}/bin/skipcpio" \
        EXORDOS_INITRAMFS_VALIDATOR="$VALIDATOR" \
        TEST_EARLY_BLOCKS="$early_blocks" \
        PATH="${TMP_DIR}/bin:${PATH}" \
        "$POST_UPDATE_HOOK" test "${TMP_DIR}/boot/initrd.img-test"
}

cp "${TMP_DIR}/payload.cpio.zst" "${TMP_DIR}/boot/initrd.img-test"
run_hook
run_post_update_hook

cp "${TMP_DIR}/early.cpio" "${TMP_DIR}/boot/initrd.img-test"
dd if="${TMP_DIR}/payload.cpio.zst" \
    of="${TMP_DIR}/boot/initrd.img-test" oflag=append conv=notrunc status=none
if zstd -t -- "${TMP_DIR}/boot/initrd.img-test" >/dev/null 2>&1; then
    echo "early CPIO fixture unexpectedly begins with a zstd frame" >&2
    exit 1
fi
run_hook
run_post_update_hook

cp "${TMP_DIR}/payload.cpio.zst" "${TMP_DIR}/boot/initrd.img-test"
size=$(stat -c %s "${TMP_DIR}/boot/initrd.img-test")
truncate -s "$((size - 8))" "${TMP_DIR}/boot/initrd.img-test"
if run_hook; then
    echo "guard accepted a truncated zstd stream" >&2
    exit 1
fi

printf 'not an initramfs\n' | zstd -q -f -1 -o \
    "${TMP_DIR}/boot/initrd.img-test"
if run_hook; then
    echo "guard accepted an unreadable initramfs archive" >&2
    exit 1
fi

rm "${TMP_DIR}/boot/initrd.img-test"
if run_hook; then
    echo "guard accepted a missing initramfs" >&2
    exit 1
fi
