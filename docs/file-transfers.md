# Rex file transfers: findings and Renux integration

Research for `feat/files`, based on the installed Rex server's self-description,
read-only capability probes, official public docs, and explicitly labeled community
implementation references. Initial discovery transferred no files and contacted no remote
hosts. The implementation was subsequently tested with disposable files on an isolated local
Rex server; it did not use the user's running sessions.

## Bottom line

Rex already has native terminal-associated uploads and downloads over its data
connection. This is not a new `rex cp` command or an SSH/rsync wrapper. The installed
CLI's help lists no dedicated upload/download/copy command. Its server advertises:

| Operation | Method | Minimum connection API revision |
| --- | --- | --- |
| Upload a local file to a terminal's machine | `com.superlogical.terminal.upload_begin` | **11** |
| Download a file from a terminal's machine | `com.superlogical.terminal.download_begin` | **13** |
| Browse directories and files | `com.superlogical.terminal.list_dir` | Not established here |

Installed CLI and running local server: `0.0.1794347992-g99caa8`, commit
`99caa8e07107e0ec57eeaa868f9f589ccd8bd7cb`, API revision 13, supporting 0 through 13.
These facts came from `rex version`, `rex --autostart=false whoami --json`, and
`rex --autostart=false api list --json`.

**Renux currently advertises revision 10** in
[`src/rex/control.zig`](../src/rex/control.zig). A new transfer implementation
therefore needs newer revision negotiation, not just the new method calls.
Probes with incomplete arguments and no session attachment opened/reserved no files:
the server's `revision_too_low` responses explicitly said uploads need revision 11
and downloads need revision 13. At supported revisions both calls instead refused
with `conflict` because the probe connection was not attached to the session.

Sources: the installed server's `/llms.txt` and `/api/help`; the three method
self-descriptions obtained with `rex api describe`; observed revision-gate responses.
The official [API guide][api-guide] recommends server-generated discovery because
it matches the connected server's version.

## What the server actually promises

### Upload

Call `com.superlogical.terminal.upload_begin` with `session_id`, `block_id`, and:

```json
{
  "args": {
    "ref": "upload:<new-lowercase-canonical-uuid>",
    "name": "screenshot.png",
    "size": 12345
  }
}
```

- `size` is the **exact** byte count. Only the last path component of `name` is used,
  without control characters.
- The result supplies `ticket` and `expires_in_ms` for a `rex.data.bytes.v1` stream.
- Optional `batch`, `index`, and `count` group files. After every file arrives, the
  **server pastes their paths into the terminal**, in batch order. Renux must not
  paste the paths a second time.
- There is **no destination directory/path argument** in this method. It is an
  attachment workflow, not a general arbitrary-path remote file writer.
- The schema does not specify the upload storage directory, retention, overwrite
  policy, file-size limit, or partial-file cleanup. Do not invent those guarantees.

Source: `rex --autostart=false api describe com.superlogical.terminal.upload_begin --json`
and the installed server's `/llms.txt`, section of the same name.

### Download

Call `com.superlogical.terminal.download_begin` with `session_id`, `block_id`, and
`args: {"ref":"download:<new-lowercase-canonical-uuid>","path":"./artifact.zip"}`.

- Only **regular files** can be downloaded. Relative paths use the terminal's
  foreground process's working directory; leading `~` means its home directory.
- The result includes absolute `path`, `name`, `size`, and `modified_at`, normally
  also `ticket` and `expires_in_ms` for `rex.data.bytes.v1`.
- `size` is for progress only: the file can change and the stream can contain more
  or fewer bytes. Do not use the initially advertised size as the EOF signal.
- Optional `version` and request `if_none_match` allow caching. A matching version
  returns `not_modified` with no ticket. An absent version means do not cache.

Source: `rex --autostart=false api describe com.superlogical.terminal.download_begin --json`
and the installed server's `/llms.txt`, section of the same name.

### Browsing and connection security

`list_dir` already accepts `path`, `files`, `prefix`, and `limit`, and returns
`path`, `home`, `status`, `entries`, and `truncated`. Entries include names and
file/symlink flags. Hidden entries are included; sorting/filtering is the client's
job. `status` distinguishes `ok`, `missing`, `not_dir`, and `denied`.

Transfer tickets are single-use, expire after `expires_in_ms`, and can only be used
by a data connection from the same user. Transfer calls require session attachment,
as the probes confirmed. The official `data.connect` contract distinguishes
`session.attach`/`session.bootstrap` from `session.attach_all`, which is insufficient
for opening data connections. Use existing authenticated connections; do not add
an anonymous listener for files. [API reference][api-reference], [remote access][remote-access].

Source for browsing: `rex api describe com.superlogical.terminal.list_dir --json`.
The [server.status reference][api-reference] says equal `host_id` values identify
servers sharing files; missing/different IDs must not be assumed to share files.
A network URL or matching-looking path alone does not establish filesystem identity.

## Byte-stream details: official gap and a concrete reference

The installed method schemas name **`rex.data.bytes.v1`**, but the installed
`/llms.txt` data-connection chapter documents the **terminal** protocol: it even
says bytes flow only server-to-client. That text cannot be taken as an upload
specification. The public [API reference][api-reference] currently omits the transfer
methods entirely; public searches for `file transfer` and `upload` did not expose a
transfer guide. Public documentation lag is not evidence the installed feature is absent.

There is a readable implementation in the independent Android client
[Rhubarb upload][rhubarb-upload] and [download][rhubarb-download], pinned to commit
`da5a66911c2b37c3f24d7ec83ea2070b9619c8fb`. This is primary evidence of that
client's implementation, **not an official Rex protocol guarantee**. Its flow is:

1. Open `/api/data`, subprotocol `rex.data.bytes.v1`, without compression.
2. Send binary HELLO: `0x01` plus the 16 decoded ticket bytes; wait for WELCOME.
3. Upload: send raw chunks, then an **empty binary message** as a half-close.
   Wait for the server's normal close (1000) before reporting confirmed completion.
4. Download: after the handshake, every binary message is file content, even if
   its first byte resembles a handshake marker. A normal close ends the download.

That reference also warns against retrying an upload automatically when the
connection fails after the half-close: the server may already have pasted its path.
The upload framing and completion flow above have now been exercised against the installed
Rex build in `zig build test-upload`; `zig build test-preview` now verifies downloads too. Do not import that
Android client's chosen file-size limits as Rex server limits.

## Implemented first increment

**One file dropped or pasted onto a remote pane is uploaded; local files insert their path.**

- [`TermView.onDrop` and clipboard paste](../src/terminal/termview.zig) share the same file
  handler, routing non-Unix-socket connections to upload. This conservatively copies even
  when a network endpoint happens to reach the local machine; it never assumes a network
  host can read a local path.
- Clipboard paste prefers original files (`GdkFileList` or `text/uri-list`), then image data,
  then ordinary text. Use Ctrl+Shift+V or the context menu's Paste. Coding-agent panes also
  handle Ctrl+V for files/images; plain-text Ctrl+V and shell literal-next remain untouched.
  Multiple files are rejected explicitly; normal text and its multiline safeguards are unchanged.
- Clipboard images are read with GDK and encoded as PNG on a GIO worker, never blocking
  typing/rendering. Their temporary files are private (0600). Remote uploads remove the local
  source on completion, cancellation, or failure. Local pastes retain their image under the
  system temp directory so the receiving program can read it later; OS temp cleanup may
  eventually remove it. A paste finishing after its pane/host is gone is discarded safely.
- [`src/rex/upload.zig`](../src/rex/upload.zig) opens an isolated revision-11 control
  connection, attaches to the session, reserves the upload, and sends asynchronously read
  chunks over `rex.data.bytes.v1`. The terminal connection stays at revision 10.
- Reads and the writer queue are bounded. The reserved size must match exactly, including
  empty files. Success requires a normal server close after the empty binary half-close.
  Cancelling or losing confirmation after half-close is reported as **unconfirmed**,
  never automatically retried. Rex alone inserts the path.
- [`src/ui/upload.zig`](../src/ui/upload.zig) tracks each upload, and the pane draws it as dim
  text after its cursor, where Rex will paste the path: `…/` and the file's name, which turns
  the theme's green from the left as the file goes, eased so it moves smoothly, then the
  percentage. Only the end of the path can be shown: Rex chooses the folder and doesn't say
  which before it pastes. It is drawn on
  the grid of cells with nothing behind it, carries on at the start of the next line when its
  own line is full, and sits in the pane's bottom corner when the cursor is hidden or scrolled
  away. A cancel button shows while the pointer is over the text, until everything is sent: a
  cancel from then on could not tell whether the file arrived. A successful upload shows no
  toast, because the pasted path is the confirmation; every other outcome is reported in a
  toast. Removing a host cancels its uploads safely while asynchronous file callbacks drain. A
  second simultaneous upload to the same pane is refused. Rex refuses files over 104857600
  bytes (100 MB).
- With a `-Ddev` build, the `RENUX_SCRIPT` command `upload /path/to/file` sends a file to the
  focused pane without a drag, for checking how an upload is drawn.
- `zig build test-upload` starts a temporary Rex with isolated config/state/cache/temp
  directories and an input recorder, never a command-executing shell. It verifies binary
  contents, empty files, symlinks, spaces/quotes/Unicode in names, no duplicate path paste,
  cancellation before/during/after sending, host removal, missing files, folders, named pipes,
  files growing/shrinking during transfer, and an older API welcome.
  Cancellation after half-close actually produced one path in testing, confirming why the
  **unconfirmed** outcome must not be blindly retried.
- `zig build test-clipboard` uses the same isolated server plus a private GTK Broadway display.
  It drives the actual terminal key/paste handlers, covering image bytes, native textures,
  copied files, URI lists, local/remote paths, Ctrl+V attachment handling, text/shell key
  preservation, pane/host removal, invalid images, write failures, and multiple-file rejection.
  It checks exact file contents, private permissions, temporary-image cleanup, and exactly one
  pasted path. Agent metadata is simulated; no Claude Code session or model request is used.

File previews now use the download API; see [file-preview.md](file-preview.md) for behavior,
limits, and the original Quick Look investigation. Multi-file batches and a general-purpose
Save Download action are not included. A later
**Download File…** action could reuse the browser in [`src/ui/goto.zig`](../src/ui/goto.zig),
then GTK's Save dialog. Its `Server.listDir` wrapper currently discards `status` and
`truncated`; preserve those for honest error handling. Save downloads to a temporary local
file and finalize only on confirmed completion; ask before replacement.

Defer recursive folders, sync, arbitrary remote writes, and remote-to-remote copies.
No dedicated remote-to-remote copy operation was found in the installed API; a
client-mediated download/upload relay is a possible future design, not verified behavior.

[api-guide]: https://www.superlogical.com/rex/docs/automate/server-api.md
[api-reference]: https://www.superlogical.com/rex/docs/reference/api.md
[remote-access]: https://www.superlogical.com/rex/docs/linux/remote-access.md
[rhubarb-upload]: https://github.com/Joshua-Wise/rhubarb/blob/da5a66911c2b37c3f24d7ec83ea2070b9619c8fb/app/src/main/java/dev/jwise/rhubarb/rex/RexUpload.kt
[rhubarb-download]: https://github.com/Joshua-Wise/rhubarb/blob/da5a66911c2b37c3f24d7ec83ea2070b9619c8fb/app/src/main/java/dev/jwise/rhubarb/rex/RexDownload.kt
