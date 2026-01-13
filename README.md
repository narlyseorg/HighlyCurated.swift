# HighlyCurated

A high-performance file organization utility for macOS that automatically categorizes files in the Downloads directory based on their extensions.

![HighlyCurated](https://img.lightshot.app/ORF333O9R-6tYscJvMTQ8A.png)

---

## Abstract

Modern computing workflows often result in accumulated files within the system's default download location. This utility provides an automated solution that monitors the `~/Downloads` directory and relocates files into predefined categorical subdirectories based on file extension analysis.

The implementation prioritizes:
- Native Swift implementation with Foundation APIs
- Concurrent file processing using Grand Central Dispatch (GCD)
- Robust locking with `flock()` and PID verification
- Case-insensitive extension matching
- Conflict resolution through atomic retry with suffix enumeration
- Unified logging via OSLog with file rotation

---

## System Requirements

- macOS 12.0 (Monterey) or later
- Xcode Command Line Tools (for compilation)
- Automator.app (for automation, included with macOS)

---

## File Categories

The utility classifies files into the following categories:

| Category | Extensions |
|----------|------------|
| Documents | doc, docx, odt, pdf, xls, xlsx, ods, csv, ppt, pptx, odp, pages, numbers, txt, rtf, md, tex, log, epub, mobi, wps, msg, wpd |
| Scripts | py, ipynb, js, jsx, ts, tsx, html, css, scss, java, class, jar, c, cpp, h, cs, php, swift, go, rb, pl, rs, sh, bash, zsh, bat, ps1, lua, r, sql, sqlite, db, json, xml, yaml, yml, toml, ini, cfg, config, env, htaccess, gitignore, pkl, kt, dart |
| Images | jpg, jpeg, png, gif, webp, tiff, tif, bmp, heic, svg, ico, psd, ai, eps, indd, raw, cr2, nef, orf, arw, dng, xcf |
| Compressed | zip, rar, 7z, tar, gz, tgz, bz2, tbz, xz, zst |
| Programs | app, pkg, exe, msi, apk, xapk, ipa, apkm, deb, rpm, appx, bin, dmg |
| Certificates | pem, crt, cer, der, p12, pfx, pki, pub, key, gpg, ovpn, asc |
| Videos | mp4, mkv, mov, avi, wmv, flv, webm, m4v, mpg, mpeg, 3gp, ts, vob, srt, ass |
| Music | mp3, wav, aac, flac, ogg, m4a, wma, alac, mid, midi |
| Disks | iso, ova, vdi, vbox, vmdk, qcow2, img |
| Fonts | ttf, otf, woff, woff2 |
| Torrents | torrent |
| Others | Unrecognized extensions |

Additionally, files matching common extensionless naming conventions (e.g., `Dockerfile`, `Makefile`, `LICENSE`, `README`) are classified under Scripts.

---

## Installation

### Step 1: Compile the Binary

Install Xcode Command Line Tools if not already present:

```bash
xcode-select --install
```

Compile the Swift source:

```bash
swiftc -O -whole-module-optimization -parse-as-library HighlyCurated.swift -o highlycurated
```

Deploy the binary to the user Scripts directory:

```bash
mkdir -p ~/Library/Scripts
cp highlycurated ~/Library/Scripts/
chmod +x ~/Library/Scripts/highlycurated
```

Verify execution:

```bash
~/Library/Scripts/highlycurated --verbose
```

### Step 2: Create Automator Folder Action

1. Open **Automator.app** (located in `/Applications/Automator.app`)

2. Select **New Document** when prompted

3. Choose **Folder Action** as the document type

4. At the top of the workflow, locate the dropdown labeled:
   ```
   Folder Action receives files and folders added to
   ```
   Click the dropdown and select **Other...**, then navigate to and select:
   ```
   ~/Downloads
   ```

5. From the Actions library (left sidebar), search for **Run Shell Script**

6. Drag the **Run Shell Script** action into the workflow area

7. Configure the action as follows:
   - **Shell**: `/bin/bash`
   - **Pass input**: `as arguments`
   - **Script content**:
     ```bash
     ~/Library/Scripts/highlycurated
     ```

![HighlyCurated Automator](https://img.lightshot.app/d4Df8qTXS7i2ohPaoZ740A.png)

8. Save the workflow:
   - Press `Cmd + S`
   - Name it `HighlyCurated` (or any preferred identifier)
   - The file will be automatically saved to `~/Library/Workflows/Applications/Folder Actions/`

### Step 3: Verification

1. Download any file using Safari or another browser

2. Observe that the file is automatically moved to the appropriate category folder within `~/Downloads/`

3. Review the log file for execution details:
   ```bash
   tail -f ~/Library/Logs/highlycurated.log
   ```

---

## Configuration

Configuration is managed via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `HIGHLYCURATED_DOWNLOADS_DIR` | `~/Downloads` | Source directory to process |
| `HIGHLYCURATED_LOG_FILE` | `~/Library/Logs/highlycurated.log` | Log file location |
| `HIGHLYCURATED_LOCK_FILE` | `/tmp/highlycurated.lock` | Lock file for concurrency control |
| `HIGHLYCURATED_MAX_RETRIES` | `100` | Maximum retry attempts for filename collisions |
| `HIGHLYCURATED_LOG_RETENTION` | `5` | Number of rotated log files to retain |
| `HIGHLYCURATED_VERBOSE` | `0` | Set to `1` for verbose logging |

Example usage with custom configuration:

```bash
HIGHLYCURATED_DOWNLOADS_DIR=/path/to/folder HIGHLYCURATED_VERBOSE=1 ~/Library/Scripts/highlycurated
```

---

## Command Line Options

| Option | Description |
|--------|-------------|
| `--verbose` | Enable verbose logging (equivalent to `HIGHLYCURATED_VERBOSE=1`) |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `2` | Another instance is running (lock acquisition failed) |

---

## Technical Notes

### Concurrency Control

The utility implements a robust locking mechanism using `flock()` with PID and process start time verification:

1. **Lock acquisition**: Exclusive non-blocking `flock()` on `/tmp/highlycurated.lock`
2. **Stale detection**: PID liveness check via `kill(pid, 0)`
3. **PID reuse protection**: Process start time comparison using `sysctl()` and `kinfo_proc`
4. **Crash durability**: Lock content persisted with `fsync()`

### Concurrent Processing

Files are processed in parallel using GCD (`DispatchQueue` with `.concurrent` attribute). Each file move operation is atomic on APFS, with automatic retry on collision.

### Network Filesystem Detection

The utility detects NFS, SMB, AFP, and other network filesystems using `statfs()` and logs a warning, as `flock()` and atomic operations may not behave reliably on such systems.

### Skipped Files

The following are intentionally ignored:
- Hidden files (prefixed with `.`)
- Incomplete downloads: `.crdownload`, `.download`, `.part`, `.tmp`, `.opdownload`
- System files: `.DS_Store`, `.localized`
- Symbolic links
- Subdirectories and their contents

### Conflict Resolution

When a file with the same name exists in the destination directory, the utility attempts atomic move operations with incrementing suffixes:
```
example.pdf → example (2).pdf → example (3).pdf
```

After 5 failed attempts, exponential backoff is applied (200µs × counter, max 10ms) to reduce contention in hot directories.

### Log Rotation

Logs are automatically rotated when exceeding 1 MB:
- Rotated files are timestamped: `highlycurated.log.20260113_231500`
- Retention policy preserves the most recent 5 rotated files (configurable)

---

## Troubleshooting

**Permission denied errors**

Ensure the binary has execute permissions:
```bash
chmod +x ~/Library/Scripts/highlycurated
```

**Another instance running (exit code 2)**

Check for stale lock files:
```bash
cat /tmp/highlycurated.lock
rm /tmp/highlycurated.lock  # Only if no instance is running
```

**Log file not created**

Manually create the log directory:
```bash
mkdir -p ~/Library/Logs
```

**Network filesystem warning**

The utility functions best on local filesystems (APFS, HFS+). Running on network shares (NFS, SMB) may result in unreliable locking behavior.

---

## Performance

Compared to shell script implementations:

| Aspect | Shell Script | Swift Binary |
|--------|--------------|--------------|
| File Operations | Fork/exec overhead | Direct syscalls |
| Concurrency | Sequential | Parallel (GCD) |
| Locking | Shell tricks | Kernel `flock()` |
| Binary Size | N/A (interpreted) | ~175 KB |
| Startup Time | ~50ms | ~5ms |

Expected speedup: 3-10x on large Downloads folders.

---

## License

MIT License. See LICENSE file for details.

---

## References

- Apple Developer Documentation: FileManager, DispatchQueue
- Darwin Manual Pages: flock(2), statfs(2), sysctl(3)
- Swift Standard Library: Foundation, os.log
