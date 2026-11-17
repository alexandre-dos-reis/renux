<p align="center"><img src="data/icons/dev.renux.png" width="128" alt="Renux icon: a penguin seen close up"></p>

# Renux

A native Linux client for [Rex](https://rex.superlogical.com), written in Zig with GTK4 and
libadwaita. It shows a Rex server's sessions, windows and panes, with live terminals drawn
through libghostty-vt.

Renux is an independent project, not made by the Rex team. It is early, so expect rough edges,
and please report them as [issues](https://github.com/zenodea/renux/issues).

![Renux over a desktop wallpaper: a sidebar of sessions, a shell, and two coding agents at work](docs/screenshots/panes.png)

## What it does

- **Your Rex sessions, as they are.** Sessions, tabs and panes live on the Rex server, so they
  are the same here, in the Rex app and on a phone. Key bindings come from your Rex config.
- **Fast terminals.** Text is drawn with libghostty-vt, with selection, find, links, box
  drawing, and your own font and theme.
- **Every tab at once.** The overview zooms out from the tab you are on to a grid of all your
  tabs, each drawn as its live terminals. A dot on a tab shows what each agent in it is doing.
  Pick a tab and it zooms back in.
- **Only the terminals.** Full screen mode hides the sidebar, the title rows and the window's
  own background, so the panes fill the window.
- **Your agents at a glance.** Panes running coding agents show what they are doing, and the
  agent board sorts them into Idle, Running, Attention and Done.
- **Files for remote panes.** Drop files, or paste copied files or a clipboard image with
  Ctrl+Shift+V. Coding-agent panes also accept attachments with Ctrl+V. Rex uploads them and
  inserts their remote paths, in order, once all have arrived. The first file's name shows at
  the cursor and fills in as they go. Local panes insert local paths. Screenshots become PNG
  files. Each file can be up to 100 MB.
- **Peek at files.** Ctrl+click a file path to see the file by it, locally or remotely: the
  lines around the one named, in syntax colors, or the picture. Enter opens the file in your
  editor in a new pane to the right (`nvim` by default; the Editor command setting changes
  it), and Shift+Enter in a new window. For a picture, Enter opens your image viewer. Hold
  Ctrl to underline a detected path; Esc closes the peek. For paths with ambiguous spacing,
  select the path and choose **Preview Selected Path** from the right-click menu, which
  offers **Open With…** for other formats. Requires Rex API 13; files up to 16 MiB.
- **Several servers.** Connect to more than one Rex server, on this computer, over Tailscale,
  or through SSH (`user@box` or `ssh://user@box:2222`). SSH uses your system's keys, config and
  agent, with one connection shared by terminals and file transfers. Trust the host and unlock
  your key in a terminal first; Renux does not answer SSH questions yet. Remote hosts can answer
  to this computer's keys and keep their own colors. See [SSH hosts](docs/ssh-hosts.md).
- **Made to look at.** Themes, a see-through window with the desktop's blur behind it, and
  custom GLSL shaders as in Ghostty: ten ship with Renux, from a CRT to a cursor that smears as
  it moves.

| Agent Board | Overview |
|---|---|
| ![Agents sorted into four columns by state](docs/screenshots/board.png) | ![Six tabs in a grid, each showing its terminals, with a dot for each agent's state](docs/screenshots/overview.png) |

| Shaders | Full screen mode |
|---|---|
| ![Three panes drawn through the CRT shader, curved and scanlined](docs/screenshots/shaders.png) | ![Only the terminals: one large pane and two stacked beside it, the desktop showing between them](docs/screenshots/fullscreen.png) |

## Installing

There are no packages yet, so Renux is built from source. You need a Rex server to connect to.

1. Install Zig 0.17 and the libraries, with their development files:

   | Distribution | Command |
   |---|---|
   | Fedora | `sudo dnf install gtk4-devel libadwaita-devel librsvg2-devel poppler-glib-devel` |
   | Debian, Ubuntu | `sudo apt install libgtk-4-dev libadwaita-1-dev librsvg2-dev libpoppler-glib-dev` |
   | Arch Linux | `sudo pacman -S gtk4 libadwaita librsvg poppler-glib` |

2. Build and install into `~/.local`, which puts the program, its desktop entry and its icon
   where your desktop looks for them:

   ```sh
   git clone --recurse-submodules https://github.com/zenodea/renux
   cd renux
   zig build -Doptimize=ReleaseFast -p ~/.local
   ```

3. Start Renux from your applications menu, or run `renux`. With Rex installed on this
   computer, it connects to the Rex server here, and starts it if it isn't running. Otherwise
   it asks for your Rex server's address.

`renux --toggle` shows or hides the running window, for a desktop shortcut.
Settings are kept in `~/.config/renux`.

## Keys

Key bindings come from your Rex config, so the keys you know work here. Renux adds two actions
of its own to bind there:

```lua
rex.bind("ctrl+a>shift+o", "client.overview.toggle")   -- every tab at once
rex.bind("ctrl+a>shift+f", "client.fullscreen.toggle") -- only the terminals
```

The overview and the agent board are off until you switch them on in Settings, under
Developer. Both actions are in the command palette too, and the overview has a button at the
foot of the sidebar.
In the overview, the arrow keys or `h` `j` `k` `l` move between tabs, Enter goes to one and
Escape goes back. `x` closes the tab the ring is on, `c` opens a new tab in its session and
goes to it, and `s` groups the tabs by session.

A remote host answers to its own Rex config. For the same keys everywhere, turn on
Settings > Remote Hosts > Use this computer's keys on remote hosts.

## Building

You need Zig 0.17, GTK 4, libadwaita, librsvg and poppler-glib, with their development files.

```sh
git submodule update --init
zig build -Doptimize=ReleaseFast
zig build test
```

The program is `zig-out/bin/renux`. Add `-Ddev` for the development hooks: screenshots, the
test script and the frame log.

`zig build test-upload` checks file uploads against a disposable local Rex server. It needs
`rex` (API revision 11 or newer) and Python 3; it does not use your running sessions.
`zig build test-clipboard` also exercises the GTK paste handler on a private display, including
images and Ctrl+V; it additionally needs `gtk4-broadwayd` and never changes your clipboard.
`zig build test-preview` uses the same isolated setup to check downloads and preview dialogs.

## License

Apache 2.0; see `LICENSE`. Bundled fonts and icons keep their own licenses, noted beside them.
