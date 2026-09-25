# Backlog

Ideas that aren't committed or scheduled. Shipped features live in the
[Changelog](https://github.com/emdzej/airlock/blob/main/CHANGELOG.md).

## Flash: verify after write

Optional verify pass after a flash: re-read the device and hash-compare
against what was written. Roughly doubles the time, so it should be a UI
toggle (e.g. `?verify=1`). Progress over the same SSE stream as the write,
reported as a separate `verify` stage.

## Flash: `.zip` images

Some OS images ship as a `.zip` with a single `.img` inside. `archive/zip`
needs random access (the central directory is at the end), so a streamed
upload can't be decompressed on the fly the way `.xz` / `.gz` are. Options:
stream-parse local file headers (works for the common single-entry,
non-data-descriptor case), or keep requiring users to extract locally.
Detect by magic bytes rather than filename.

## Removable-media check for destructive targets

In addition to `ID_BUS=usb` and the OS-disk refusal, only offer format /
flash targets whose `/sys/class/block/<dev>/removable` is `1`, or at least
warn in the confirm dialog when it isn't (USB SSDs typically report `0`,
so a hard refusal would be too strict).
