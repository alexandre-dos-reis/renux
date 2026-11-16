# File previews: Rex macOS and a Linux equivalent

## Implemented on `feat/files`

- Ctrl+hover underlines detected paths; Ctrl+click shows a peek by the path: the file's name
  with its language's icon, its size, and thirteen lines with the named one in the middle, or a
  picture as tall as those lines. Web URLs still open the browser. OSC 8 `file://` links peek at files on the
  pane's host. The context menu's **Preview Selected Path** still opens the full preview.
- In the peek, Enter opens a text file in an editor in a new pane to the right of the pane
  that named it, and Shift+Enter in a new window. A picture goes to the desktop's own
  app for pictures, and a file with no peek to its list of apps. A file on this computer is
  opened where it is; one on another host as a private copy under its own name. The editor is started by typing the **Editor command** setting
  (`nvim +{line} {path}` by default) at the new pane's shell, so on a remote pane it runs on
  that host and nothing is downloaded for it. The command gets the file's whole path, which
  Rex reports as the download begins; a key pressed before that waits for it.
- Coding agents link the files they mention, and most give the link a bare path such as
  `src/main.zig` or `src/main.zig#L42` and no scheme. Those are files on the pane's host and
  open the peek, like `file://` links. When only the path is the link, as in a tool's
  `read src/main.zig:410-420`, the line written after it is used. A range of lines after a
  path in plain text, `path:417-430`, is read as its first line.
- The lines are colored by `src/ui/highlight.zig`: comments, strings, numbers and each
  language's own words, in the pane's terminal colors. It reads words and marks only, with no
  grammar, so a comment or string that began on an earlier line isn't known to it.
- The peek keeps one size from the moment it opens. GTK closes a popover whose size changes
  while it is open, which a first version did as soon as the file arrived. It opens once the
  file is in it, or after 120 ms without it, so a nearby file never shows as "Loading".
- Path detection supports absolute/relative paths, `~`, filename extensions, quoted spaces,
  soft wraps, and `path:line:column`, whose line the peek and the editor go to. Selection → **Preview Selected Path** is the fallback.
  Unquoted paths containing spaces remain ambiguous; extensionless bare names need selection.
- Both local and remote files use a dedicated API-13 download connection. Rex resolves paths
  against the foreground process's current directory, so Renux never guesses a local path
  for a remote file. A path printed before a directory change may need its absolute form.
- Downloads are asynchronous and capped at **16 MiB of actual received data**, with a timeout
  and cancellation on dialog close or host removal. Bytes become visible only after normal
  server close. There is no persistent cache and no download during hover.
- Inline previews show UTF-8 text up to **1 MiB** and PNG/JPEG/GIF images, with Fit/Actual Size.
  Image headers are checked before worker-thread decoding: at most 16,384 pixels on either
  axis and 32 million pixels total. Binary/unsupported/oversized-to-render files offer
  **Open With…**; files over the transfer cap are not downloaded at all.
- Open With creates a private temporary copy and asks the desktop to choose an application;
  no shell execution. Successful external opens retain the copy for OS temp cleanup because
  the other app may read it later. Otherwise closing the dialog removes the temporary copy.
- `zig build test-preview` checks exact downloaded bytes and real GTK dialog rendering using
  a disposable Rex server and private Broadway display, including empty/binary files, relative
  paths, symlinks, missing files, directories, size limits, cancellation, and older API rejection.
  Unit tests also check partial-transfer rejection, byte caps, path detection, and web-link
  precedence. Desktop Open With app selection and physical Ctrl-click have not been manually tested.

## Original research

Sources below were initially read without transferring files, opening panes, contacting
remote Rex hosts, or changing server/configuration. Later verification uses isolated test servers.
**Bottom line:** reuse Rex's file discovery/download transport, not Apple's preview UI.
The public docs establish the Mac action, but do **not** establish how the Mac client
fetches remote previews. A download-to-local-cache workflow is a Linux recommendation,
not a verified description of Rex.app internals.

## What is documented about Rex for Mac

- [Mac Actions][mac-actions] lists **Quick Look**, action **`client.quick_look`**,
  default shortcut **`cmd+y`** (⌘Y), with the description: “Previews the files and web
  links on screen in Quick Look.” This is a **client action**, not a server-side
  file-rendering RPC. The reference says action names can be bound to keys or run
  with `rex do`; that does not make the macOS UI portable to another client.
- That entry does **not** specify path detection, selection versus pointer behavior,
  supported file types, remote-file fetching, cache layout/retention, or size limits.
  Hidden search keywords such as “hover” are not a behavioral specification.
- [Mac Settings][mac-settings] documents link-launch confirmation/trust settings and
  an integrated path browser, but no Quick Look remote-download/cache setting.
  Neither this page nor the action reference promises preview support for every
  remote file. **Do not infer that remote previews are unsupported, either.**
- The public [documentation index][index] and [API reference][api] currently provide
  no transfer-method specification. The installed server's self-description is
  newer and explicitly documents `download_begin` and `upload_begin`.

## What Linux can reuse: installed server contract

Local baseline: Rex **`0.0.1794347992-g99caa8`**, API **13**; downloads require
connection revision **13**, uploads **11** (baseline supplied for this task; also
recorded in [file-transfers.md](file-transfers.md)). Renux's main control connection
currently advertises **10** in [`src/rex/control.zig`](../src/rex/control.zig).
The isolated revision-11 upload connection alone does **not** enable downloads;
a future preview path needs revision 13, with negotiation/older-server handling.

These facts are from the **installed server**, not inferred from the Mac action:

| Capability | Documented behavior |
| --- | --- |
| `com.superlogical.terminal.list_dir` | `files: true` includes non-directory entries. Accepts `path`, `prefix`, `limit`; returns absolute `path`, `home`, `status`, entries, and `truncated`. Hidden entries are included; sorting/filtering belongs to the client. A `file` flag means non-directory, not necessarily a downloadable regular file. |
| `com.superlogical.terminal.download_begin` | Opens a **regular file on the terminal's machine**. Send `session_id`, `block_id`, and `args` containing `ref: "download:<new-lowercase-canonical-uuid>"` and `path`. Relative paths use the terminal foreground process's working directory; leading `~` means home. |
| Download result | Absolute `path` (symlinks left unresolved), `name`, `size`, `modified_at`, normally `ticket` and `expires_in_ms`. The single-use ticket opens a **`rex.data.bytes.v1`** stream and is usable only by a data connection from the same user. |
| Changing files | `size` is **progress metadata, not an EOF condition**: the stream may contain more or fewer bytes if the file changes. `modified_at` is not a safe cache validator because programs can set it arbitrarily. |
| Version caching | Optional opaque `version`: “The same path with the same version has the same contents.” Send it as `if_none_match` on a later request for that path; `not_modified` means reuse the existing copy, with **no ticket/transfer**. If `version` is absent—e.g. the file changed within the last second, or the server cannot tell—the download **must not be cached**. |

Reproduce the read-only discovery (the first two commands **describe**, not invoke,
block methods):

```sh
rex --autostart=false api describe com.superlogical.terminal.download_begin --json
rex --autostart=false api describe com.superlogical.terminal.list_dir --json
curl --unix-socket /run/user/1001/rex/server.sock http://localhost/llms.txt
```

The generated `/llms.txt` says it matches this server and describes API revision 13.
Its block-method sections contain the contracts above. Its binary/data chapter,
however, describes **`rex.data.terminal.v1`**, not a complete bytes-transfer protocol.
Do not reuse terminal framing, offsets, or resume rules for downloaded file bytes.
No server-side thumbnail/rendered-preview method was found in this description.

**Optional community reference, not official protocol:** independent Android client
[Rhubarb's `RexDownload.kt`][rhubarb], pinned to commit
`da5a66911c2b37c3f24d7ec83ea2070b9619c8fb`, uses `/api/data` with
`rex.data.bytes.v1`, sends binary HELLO (`0x01` + decoded ticket), consumes WELCOME,
then treats subsequent binary messages as raw file content and normal close (1000)
as completion. It removes partial files on failure. This is evidence of that
client's implementation, **not** proof of Rex.app's preview implementation or an
official framing guarantee. Its 1 GiB cap is client policy, not a Rex server limit;
it does not implement the version-cache flow above. The implemented download framing has
since passed end-to-end tests against the installed Rex server.

## Apple's Quick Look is a platform UI, not Rex wire protocol

Apple documents [`QLPreviewPanel`][apple-panel] in **Quick Look UI**, available on
**macOS**, as the native shared panel for previewing a list of items, supplied through
a data source. [`QLPreviewItem.previewItemURL`][apple-url] must be a **file-type URL**.
These AppKit/macOS facilities are not Linux/GTK components, and do not themselves
provide Rex remote-file access. The sources do not reveal which Apple API Rex.app
actually uses. Its documented web-link previews also cannot be explained solely by
the file-URL contract.

**Inference:** a client can materialize remote bytes into a local file and give that
file to a local previewer. The installed download/cache API supports that design,
but no examined official source proves that this is Rex.app's actual pipeline.

## Initial Linux recommendation (superseded by the implementation above)

1. Start with an explicit **Preview File…** action and path/picker, not screen-wide
   path detection, hover behavior, web previews, or Finder shortcut emulation.
   Reuse the browser in [`src/ui/goto.zig`](../src/ui/goto.zig) and `list_dir`, but
   return the chosen path to preview code rather than its current insert/`cd`
   behavior. Surface listing errors/truncation.
2. Use a verified local file directly only when filesystem identity is established:
   the server documents block `host_id` as machine/account identity. A remote-looking
   connection URL or coincidentally matching path does not establish shared files.
   Otherwise fetch through `download_begin` on an attached, revision-13 connection,
   reusing transport/authentication infrastructure from uploads, **not** its revision
   or upload-specific completion/paste behavior.
3. Download off the GTK main thread to a private temporary file; only expose a
   completed file. Bound actual bytes, decoded image dimensions, and text rendered;
   support cancellation and remove partial files. Namespace any validated cache by
   host/account and absolute path, retain its opaque version, and revalidate with
   `if_none_match`. With no version, use an ephemeral file rather than a reusable
   cache entry. Cache retention/eviction is Linux client policy, not a server promise.
4. A small GTK dialog for **inert text and images** is the smallest native preview.
   Offer an explicit **Open With…** fallback for other types using
   [`GtkFileLauncher`][gtk-launcher] (GTK 4.10+). That launches an application; it is
   not a Quick Look equivalent by itself. Never execute a remote filename through
   a shell or automatically launch executable/active content.

Defer PDFs/media breadth, custom preview plugins, automatic remote downloads and
persistent caches until transport completion/error semantics have been validated.
The implementation keeps downloads separate from upload completion/paste behavior.

[index]: https://www.superlogical.com/rex/docs/llms.txt
[mac-actions]: https://www.superlogical.com/rex/docs/reference/mac-actions.md#action-client-quick-look
[mac-settings]: https://www.superlogical.com/rex/docs/reference/mac-settings.md
[api]: https://www.superlogical.com/rex/docs/reference/api.md
[apple-panel]: https://developer.apple.com/documentation/quicklookui/qlpreviewpanel
[apple-url]: https://developer.apple.com/documentation/quicklookui/qlpreviewitem/previewitemurl
[gtk-launcher]: https://docs.gtk.org/gtk4/class.FileLauncher.html
[rhubarb]: https://github.com/Joshua-Wise/rhubarb/blob/da5a66911c2b37c3f24d7ec83ea2070b9619c8fb/app/src/main/java/dev/jwise/rhubarb/rex/RexDownload.kt
