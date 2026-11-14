#!/usr/bin/env bash
set -euo pipefail
out="${1:?output directory}"
mkdir -p "$out"
for bin in sgdisk mkfs.ext4 dumpe2fs e2fsck qemu-img sha256sum; do
  command -v "$bin" >/dev/null || { echo "Missing $bin"; exit 1; }
done
raw="$out/rwf809-ext4.raw"
vhdx="$out/rwf809-ext4.vhdx"
truncate -s 8589934592 "$raw"
sgdisk --clear --new=1:2048:-2048 --typecode=1:0700 --change-name=1:RWF809EXT4 "$raw"
sgdisk --verify "$raw"
# Partition: 1MiB offset, 1MiB end reservation; exactly 2096640 4096-byte blocks.
mkfs.ext4 -F -b 4096 -E offset=1048576 \
  -O '^orphan_file,^metadata_csum_seed,^encrypt,^casefold,^inline_data,^mmp,^ea_inode,^large_dir' \
  -L RWF809EXT4 "$raw" 2096640
# Independently inspect just the FS partition, never the raw GPT header.
dd if="$raw" of="$out/ext4-partition.img" bs=1048576 skip=1 count=8190 status=none conv=sparse
dumpe2fs -h "$out/ext4-partition.img" >"$out/dumpe2fs-header.txt" 2>&1
e2fsck -fn "$out/ext4-partition.img" >"$out/e2fsck.txt" 2>&1 || {
  cat "$out/e2fsck.txt"
  exit 1
}
if grep -Eq '(^|[[:space:]])(orphan_file|metadata_csum_seed|encrypt|casefold|inline_data|mmp|ea_inode|largedir)([[:space:]]|$)' "$out/dumpe2fs-header.txt"; then
  echo "Unsupported ext4 feature unexpectedly present" >&2
  exit 1
fi
qemu-img convert -f raw -O vhdx -o subformat=dynamic "$raw" "$vhdx"
qemu-img info -f vhdx "$vhdx" >"$out/vhdx-info.txt"
sha256sum "$vhdx" >"$out/vhdx.sha256"
echo "RWF809_EXT4_IMAGE_PASS $(cat "$out/vhdx.sha256")"
# Upload only needed virtual disk + proof files; do not archive raw/partition.
rm -f "$raw" "$out/ext4-partition.img"
