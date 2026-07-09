# Backlog

Features and ideas outside the M0–M4 plan. Not committed, not scheduled.

## Flash OS image to a target device (Web UI)

User uploads an OS image (e.g. Raspberry Pi OS `.img` or `.img.xz`), picks a target
block device, and airlockd writes it byte-for-byte to that device. Turns Airlock
into a "network Etcher" — useful for imaging spare Pi cards from a laptop with no
USB ports free.

### Sketch

- New destructive endpoint: `POST /api/drives/:id/flash` with `{source: "upload"|"path", verify: bool}`.
- Same type-to-confirm UX as `format`.
- Same LED state: fast blink during flash.

### Where does the image data come from?

The Pi's root is read-only and tmpfs is bounded by RAM (Pi 4 has 2–8 GB), so we
can't buffer a full image in memory. Three options, ranked:

1. **Stream upload directly to the target device.** HTTP multipart chunks → optional
   `xz`/`gz` decompressor → `dd`/write to `/dev/sdX`. No intermediate storage. Best UX.
2. **Flash from an already-mounted drive.** User uploads the image via the existing
   file browser to Drive A, then flashes it to Drive B. Two-step but simple.
3. **Combined:** support both, default to (1) in the UI, fall back to (2) if the
   client can't stream.

### Safety

- Refuse to flash the OS device (identify by checking the block device backing `/`).
- Only allow removable block devices as targets (`/sys/class/block/*/removable == 1`).
- Same type-to-confirm modal as `format`.
- Optional verify pass: re-read the device and hash-compare against the source
  (doubles the time; UI toggle).

### Compressed inputs

Pi OS images ship as `.img.xz` most often. Also `.img.gz`, `.zip` (single .img inside),
and raw `.img`. Detect by magic bytes, not filename. Piping through `xz -d` or Go's
`compress/gzip`, `archive/zip` covers the common cases.

### Progress

Same SSE endpoint pattern as format progress. Report `bytes_written`, `total_bytes`
(known from Content-Length for uncompressed uploads; unknown for `.img.xz` unless
we parse the xz footer or trust a header).
