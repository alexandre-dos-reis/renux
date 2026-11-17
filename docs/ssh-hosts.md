# SSH hosts

Choose **Add Remote Host** and enter `user@box` or `ssh://user@box:2222`. An SSH
config alias works too: `ssh://devbox`. The host joins the sidebar like an HTTP or
Tailscale host; terminal panes, splits, uploads and file peeks use the same tunnel.
A bare address without `@` or a scheme still means HTTP.

## What is needed

- OpenSSH's `ssh` on the computer running Renux, with stream-local forwarding
  support (OpenSSH 6.7 or newer).
- SSH access to the remote account, using an unencrypted key, an already-unlocked
  key, or an agent available to the Renux process (`SSH_AUTH_SOCK` or OpenSSH's
  `IdentityAgent`). Existing SSH config, identity files, aliases and proxies apply.
- A trusted host key in the known-hosts file OpenSSH uses. Renux enforces strict
  checking; it never accepts a new or changed host key automatically.
- Rex on the remote noninteractive PATH, or at `~/.local/bin/rex`. Renux asks it to
  find or start the account's personal server. `REX_AUTOSTART=0` on the remote
  machine asks for status without starting a server. File peeks need Rex API 13.
- The SSH server must allow local Unix-socket forwarding
  (`AllowStreamLocalForwarding`); no Rex TCP listener or anonymous access is needed.

Before adding the host, log in with `ssh user@box` (or `ssh -p 2222 user@box`),
check the host fingerprint, and unlock/load the key in your agent if necessary.
For an agent launched from a terminal, Renux must inherit that agent's environment.
There is no password, passphrase or host-key question dialog in this version.
A failure appears on Renux's existing **Can't reach Rex** page with SSH's diagnostic
and a **Try again** button. Resolve the question in a terminal, then retry.

## Choosing a socket

To use a particular existing Unix socket rather than discover the personal server:

```text
ssh://user@box:2222/run/user/1000/rex/server.sock
```

This also works for a shared server if the SSH account can access its socket.
No remote Rex executable is needed for an explicit socket if the server is
already running. Socket paths are literal absolute paths, not shell expressions;
colon, percent escapes, query strings and fragments are not supported.

## How the transport works

Renux keeps the SSH address in settings and creates a private temporary directory
(mode 0700) for a local Unix socket. A single system `ssh -N -T -L
LOCAL_SOCKET:REMOTE_SOCKET` process forwards it, with a socket mask of 0177.
Control WebSockets, terminal byte streams and each upload/download WebSocket all
connect through that local socket, using separate channels in the same SSH
connection. There is no extra Rex framing or protocol adapter.

If the address omits a socket, a short SSH command first runs `rex server start
--json` (or `rex server status --json` when remote autostart is off) and reads its
`endpoint`. This follows the installed Rex CLI's Unix transport. Renux does not
rely on the CLI's internal `ssh-tunnel` helper or its JSON event protocol.

SSH runs in BatchMode, with no prompts or persistent ControlMaster. A lost tunnel
uses the normal host reconnect path. Removing the host or quitting stops it and
removes the temporary socket. On Linux, the SSH child is also killed if Renux
crashes or receives SIGTERM; a hard exit may leave an empty temporary directory.
Remote Rex sessions are not stopped when the tunnel closes.

## Limits and checks

This version supports remote **Unix sockets**, not Windows named pipes or Rex's
stdio fallback. It has no in-app SSH key import, agent selection, password login,
passphrase prompt or host-key approval. Configure those through OpenSSH first.

`zig build test` covers SSH address forms, port and forwarding-argument validation,
existing URL normalization, host labels, bootstrap/forward startup, error messages
and cancellation cleanup. Lifecycle tests use a fake SSH executable, not your
server or credentials. End-to-end testing used a private nonroot sshd with its
own keys/known-hosts file and a separate Rex/KWin rig: adding a host, terminal
input, splits, file upload bytes, text file peeks, a host-key failure, reconnect,
and child-process cleanup. No real remote machine or Windows host was tested.

## Sources

- [Rex Remote Access: SSH](https://www.superlogical.com/rex/docs/linux/remote-access#ssh)
  documents `ssh://[USER@]HOST[:PORT][/SOCKET]`, system SSH, remote prerequisites
  and autostart.
- [Rex Mac settings: Remote Hosts](https://www.superlogical.com/rex/docs/reference/mac-settings#remote-hosts)
  describes host management, SSH questions and agent selection.
- `rex hosts --help`, `rex hosts add --help`, `rex server status --json`, and a
  verbose `rex -S ssh://… -vv ls --json` trace against the private rig confirmed
  the endpoint and socket-forwarding behavior. No hosts were added to Rex's own
  host list.
