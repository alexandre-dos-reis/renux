# Port forwarding

## Using it

Ctrl+click an HTTP or HTTPS link to `localhost`, `127.0.0.1`, `[::1]` or `0.0.0.0` with
an explicit port in a remote pane. Renux starts a forward on a free local port and opens
`127.0.0.1:<local port>` in your browser, preserving the scheme, path, query and fragment.
Links in panes reached over `unix://` still open directly. Other hosts and schemes are not
intercepted.

**Forward Port…** in Commands, or the Rex action `client.host.forward_port`, opens a picker
for the focused host. It lists the focused terminal's listening TCP sockets and their programs.
Type a port, `host:port`, `[IPv6]:port`, or an HTTP(S) URL with an explicit port, then press
Enter. The list also filters by port, address or program. Wildcard listening addresses are
forwarded through loopback (`0.0.0.0` through IPv4; `::` through IPv6).

The bottom of the picker shows this window's open forwards for that host: destination on the
left, local listening address on the right. The close icon ends a forward, not its server
program. Closing the picker leaves forwards running. Removing the host or quitting the window
normally closes them. A forward is reused for the same Rex host, destination address and port,
including while it is still starting. Forwards belong to this Renux process, not every Renux
window or other Rex clients.

## Requirements and limits

- Install a Rex CLI and server that support `rex forward open`. Renux invokes the CLI on PATH;
  it does not install or update it. Missing support produces a message, never an unforwarded
  remote-localhost browser launch.
- Port discovery requires server API 15. It uses its own revision-15 control connection, leaving
  the terminals' revision-10 connection unchanged. Older servers can still accept a typed
  target if their CLI/server supports forwarding.
- Forwards bind only `127.0.0.1`, never a public interface. The destination is resolved on the
  pane's host. Only TCP is supported. This is local forwarding, not reverse forwarding.
- Discovery is a snapshot when the picker opens. Reopen it to refresh. Rex only sees programs
  still attached to the terminal, so daemons or inaccessible processes may be absent. Partial,
  unsupported and truncated replies are labelled; a missing target can always be typed.
- A browser uses the local address in its Host header. Applications that require their original
  Host header or an HTTPS certificate for the original hostname may reject it. Renux never
  disables certificate checks.
- Rex's CLI handles reconnecting. Existing TCP connections can reset on a disconnect. Forwards
  are not saved in Renux settings. A forcibly killed/crashed Renux may leave CLI children or
  tunnel blocks; inspect them with `rex -S <host> forward ls` and close the specific unwanted
  forward with `rex -S <host> forward close <id>`.

## Why the CLI carries the traffic

The installed server advertises `com.superlogical.tunnel.dial` and `.listen`, their creation
options, `session.new_block`, `session.own_block`, `data.connect` and the generic
`rex.data.bytes.v1` stream. The listen tunnel's `connection_requested` event documents a
server-issued stream reference. Neither the published full docs nor the installed creator's
schema documents how a **dial** owner chooses/names its per-connection stream reference.
Inspecting a CLI-created dial tunnel on a private server reports its target, local address,
owner and connection count, but no dial reference contract. Renux therefore does not invent
one. It uses the documented `rex -S <host URL> --autostart=false forward open --no-open
--bind 127.0.0.1 --session <session> http://<destination>:<port>` child process.

The first printed local URL supplies the allocated port. Output is read asynchronously and
bounded before the address arrives, with a startup timeout. Browser URLs are rewritten from
the original target, not shell-expanded. Arguments are passed separately; inherited Rex
server/session/block/client variables are removed. The child is interrupted to close the
forward cleanly, then force-stopped after two seconds if necessary. Renux drains that cleanup
when quitting normally.

## Checks

`zig build test` includes exact-loopback classification, invalid/ambiguous authority rejection,
port bounds, and URL rewriting with encoded paths, queries and fragments.

`zig build test-forward` starts a disposable Rex with a loopback HTTP control endpoint and
an HTTP server in its terminal. It checks the forwarded response bytes and request path,
listener reuse, cleanup on host removal and cancellation before readiness, and absence of
leftover tunnel blocks. It uses isolated settings and never reaches the user's Rex server.
