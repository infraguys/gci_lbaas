# Genesis Core Image: LoadBalancer as a Service

## Boot safety on small guests

LBaaS guests generate initramfs archives with low-memory zstd settings. Dracut
writes each boot archive to a temporary path, validates both its compressed
payload and the full archive, then atomically replaces the last known-good
initramfs. Kernel and initramfs post-update hooks repeat validation before GRUB
is regenerated, so a failed package trigger cannot publish a latent boot
failure.

### Release gate

Before this image is merged or released, build the candidate and exercise it as
a 512 MiB guest with no swap. The acceptance run must prove that a forced
`update-initramfs` failure preserves the checksum of the current boot archive,
then complete a package-triggered initramfs update and kernel reinstall while
at least 96 MiB of additional resident memory is held. Finish with two full
power-off/start cycles; the initramfs validator, package audit, guest agent, and
nginx must pass after each cycle, with no OOM or kernel-panic event.

The external acceptance runner must publish a successful
`lab/minimum-memory-acceptance` commit status for the exact candidate revision.
Branch protection requires that status, so the isolated script tests alone
cannot make a revision mergeable.
