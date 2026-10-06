# overleaf.nvim

Neovim plugin for real-time collaborative LaTeX editing on [Overleaf](https://www.overleaf.com).

Edit your Overleaf projects directly in Neovim with full real-time collaboration support via Operational Transformation (OT). Use your favorite Neovim plugins — treesitter, LSP, snippets, copilot, and more — while collaborating with others on Overleaf.

## Features

- **Real-time collaboration** — edits sync instantly with other Overleaf users via OT
- **Full Neovim ecosystem** — treesitter, LSP, snippets, copilot, and all your plugins work out of the box
- **File tree** — browse and manage project files in a sidebar
- **Auto-authentication** — extracts session cookie from Chrome automatically (macOS)
- **Auto-reconnect** — recovers from disconnects and document restores seamlessly
- **Compile & PDF preview** — compile LaTeX and open the PDF
- **Comments & reviews** — view, reply, resolve comment threads
- **Collaborator cursors** — see where other users are editing
- **File management** — create, delete, rename, upload files
- **History** — view project version history
- **Diagnostics** — chktex linter + LaTeX compile errors via `vim.diagnostic`
- **LSP support** — auto-attaches texlab, ltex, harper_ls to overleaf buffers
- **Local file sync** — mirror documents to disk for external tools (Claude Code, etc.)
- **Safe session shutdown** — flush pending edits and keep Overleaf buffers out of saved editor sessions

## Requirements

- Neovim >= 0.10
- Node.js >= 18
- An [Overleaf](https://www.overleaf.com) account
- Chrome / Chromium (for automatic cookie extraction) or a session cookie

## Installation

### lazy.nvim

```lua
{
  'richwomanbtc/overleaf.nvim',
  config = function()
    require('overleaf').setup()
  end,
  build = 'cd node && npm install',
}
```

If Node.js is not on your default PATH (e.g., installed via Homebrew on macOS):

```lua
{
  'richwomanbtc/overleaf.nvim',
  config = function()
    require('overleaf').setup({
      node_path = '/opt/homebrew/bin/node',
    })
  end,
  build = 'cd node && npm install',
}
```

### Manual

```sh
git clone https://github.com/richwomanbtc/overleaf.nvim ~/.local/share/nvim/lazy/overleaf.nvim
cd ~/.local/share/nvim/lazy/overleaf.nvim/node && npm install
```

## Authentication

### Option 1: Chrome (automatic)

Just log in to [overleaf.com](https://www.overleaf.com) in Chrome. The plugin extracts the session cookie automatically. If you have multiple Chrome profiles, you'll be prompted to select one.

### Option 2: Manual cookie

Create a `.env` file in your working directory:

```
OVERLEAF_COOKIE=your_overleaf_session2_cookie_here
```

Or pass it directly in setup:

```lua
require('overleaf').setup({
  cookie = 'your_overleaf_session2_cookie_here',
})
```

> **Warning:** If you use this method, make sure your Neovim config is not committed to a public dotfiles repository — the cookie would grant full access to your Overleaf account.

To get the cookie manually: open overleaf.com in your browser → DevTools (F12) → Application → Cookies → `www.overleaf.com` → find `overleaf_session2` → copy the cookie value (starts with `overleaf_session2=s%3A...`).

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Overleaf` | Connect (or show status if connected) |
| `:Overleaf connect` | Connect to Overleaf |
| `:Overleaf disconnect` | Disconnect |
| `:Overleaf compile [fast\|normal]` | Compile LaTeX project (normal by default) |
| `:Overleaf pdf [reload]` | Reopen the downloaded PDF, or force a Sioyek refresh |
| `:Overleaf tree` | Toggle file tree |
| `:Overleaf projects` | Switch project |
| `:Overleaf status` | Show connection status |
| `:Overleaf jump` | Jump to a collaborator's current cursor (choose when there are multiple) |
| `:Overleaf new [name]` | Create new document |
| `:Overleaf mkdir [name]` | Create new folder |
| `:Overleaf delete` | Delete file/folder |
| `:Overleaf rename` | Rename file/folder |
| `:Overleaf upload [path]` | Upload local file |
| `:Overleaf comments` | List all comments |
| `:Overleaf comments refresh` | Refresh comments from server |
| `:Overleaf history` | View project history |
| `:Overleaf sync` | Sync all documents to/from disk |
| `:Overleaf sync import` | Import external changes from disk to Overleaf |
| `:Overleaf sync export` | Export all documents to disk |

### Default Keymaps

| Key | Description |
|-----|-------------|
| `<leader>oc` | Connect |
| `<leader>od` | Disconnect |
| `<leader>oj` | Jump to collaborator (picker if multiple editors are connected) |
| `<leader>ob` | Build normally |
| `<leader>of` | Build in Fast [draft] mode |
| `<leader>ot` | Toggle file tree |
| `<leader>or` | Read comment at cursor |
| `<leader>oR` | Reply to comment |
| `<leader>ox` | Resolve/reopen comment |

### Collaboration statusline

When Heirline is already in use (including AstroNvim's default statusline), the
plugin automatically adds a project-wide sync indicator and collaborator names
with their open file paths. Names use the same colors as their in-buffer cursor
annotations. No AstroNvim configuration changes are needed. The component is
hidden when no project is open; on narrow screens, presence contracts to a count.

For example: `│ Alice · chapters/intro.tex  ✓`, with the sync symbol at the
right-hand corner after the collaborators. Every sync state occupies the same
three display cells (a symbol with padding); no elapsed time is shown, so sync
updates do not shift the rest of the status bar.
The checkmark appears only when **all latest local edits** have been confirmed by
Overleaf's `otUpdateApplied` event, not its earlier queue/API response. Pending
edits show `⧖`; missing confirmations or discarded edits during recovery show `!`;
a disconnected project shows `×`. Before any local edit has been confirmed, `○`
indicates no edits yet. Connected users are refreshed every ten seconds to
discover stationary editors. Remote edits do not count as confirmation of yours.

Use `<leader>oj` (or `:Overleaf jump`) to open a collaborator's live document at
their latest cursor. With multiple connected editors, the normal Neovim UI picker
lets you choose by name and file. Editors without an open text document are shown
but cannot be jumped to. This is a one-time jump, not continuous cursor following.

For a custom Heirline setup, `require('overleaf.statusline').component()` returns
the component; the automatic integration avoids adding a second copy.

For citation and label completion, Overleaf reuses your editor's attached TexLab
client instead of starting another one with a different project root. Its
fallback LSP integration also prevents duplicate TexLab attachments on live
Overleaf buffers, without changing LSP behavior for other files.

### Sidekick context

With `sync_dir` enabled, Sidekick's file, line, position, and visual-selection
prompts work on live Overleaf buffers. The plugin automatically recognizes its
own mirrored `acwrite` buffers as Sidekick file context, preserving Overleaf's
save/sync handling. No Sidekick source or AstroNvim configuration changes are
needed. Other special buffers and `overleaf://` documents without a readable
local mirror retain Sidekick's normal behavior.

Live Overleaf buffers are also marked as editor targets for Snacks pickers.
AstroNvim's file searches open results in the document window rather than
falling back to a Sidekick terminal or explorer split. Existing search keymaps
and Overleaf save handling remain unchanged.

### Tree Keymaps

| Key | Description |
|-----|-------------|
| `Enter` | Open document |
| `a` | New document |
| `A` | New folder |
| `d` | Delete |
| `r` | Rename |
| `u` | Upload file |
| `R` | Refresh tree |
| `q` | Close tree |

## Configuration

```lua
require('overleaf').setup({
  -- Path to .env file containing OVERLEAF_COOKIE (default: '.env')
  env_file = '.env',

  -- Session cookie (overrides .env)
  cookie = nil,

  -- Path to Node.js binary (default: 'node')
  node_path = 'node',

  -- PDF viewer executable, 'skim' for macOS Skim, or 'sioyek' for automatic reloads.
  pdf_viewer = 'skim',

  -- Compile whenever an Overleaf buffer is written (default: true)
  -- Disable this when an auto-save plugin causes repeated compilations.
  compile_on_write = true,

  -- File tree implementation: 'native' or 'neo-tree' (default: 'native')
  -- Neo-tree requires sync_dir so it has a local project directory to show.
  tree_provider = 'native',

  -- With the Neo-tree provider, use this explorer key for the Overleaf tree
  -- while connected and the normal working-directory tree otherwise.
  explorer_key = '<leader>e',

  -- Ask Mason to install TexLab when Mason is available (default: true).
  -- Set this to false if TexLab is managed elsewhere.
  ensure_texlab = true,

  -- Log level: 'debug', 'info', 'warn', 'error' (default: 'info')
  log_level = 'info',

  -- Local file sync directory for external tools like Claude Code (default: nil = disabled)
  -- When set, all documents are mirrored to disk and external changes are synced back.
  sync_dir = '~/.overleaf',

  -- Set to false to disable default keymaps
  keys = true,
})
```

With `pdf_viewer = 'sioyek'`, the plugin opens the PDF on the first successful
compile. Further compiles only replace the file atomically; Sioyek's automatic
reload handles the update without a forced cache-clearing reload or repeated
open commands. Switching to a different PDF opens that file. On macOS, install
the app at `/Applications/sioyek.app`; elsewhere, `sioyek` must be on `PATH`.
Automatic reload still depends on Sioyek detecting the file change.

Use `:Overleaf pdf` to reopen the last downloaded PDF if you closed the viewer,
or `:Overleaf pdf reload` to force a refresh if automatic reload misses an
update (the forced refresh can blink). Other viewers and custom command tables
keep their existing open-after-every-compile behavior. For example,
`{ '/custom/path/sioyek', '--reuse-window', '--execute-command', 'reload' }`
forces a reload after each compile; the PDF path is appended as one argument.

With both `sync_dir` and `tree_provider = 'neo-tree'`, the Overleaf tree uses
Neo-tree's filesystem view. Document opens are routed back through Overleaf's
live OT buffers. Creating, renaming, and deleting entries from Neo-tree is
routed through Overleaf and then reflected in the local mirror; local-only
copy and move operations remain blocked. `explorer_key` opens the
Overleaf-scoped tree while connected and the normal working-directory explorer
otherwise.

Live document buffers keep the mirror's filename but use `buftype=acwrite`.
While connected, opening a project text file through Neo-tree (including
alternate open mappings), a file picker, `:edit`, or a split automatically
attaches it to live OT. Preview buffers and unrelated files are left alone.
Closing and reopening a buffer restores its change listener without resetting
pending edits. If an ordinary mirror buffer already has unsaved local edits,
save those before opening it through Overleaf so they are not overwritten.

Your normal- and insert-mode cursor positions are shared with browser editors
using your Overleaf account's name. Existing collaborators' cursor positions
are fetched on connection and shown as soon as their document is opened;
they do not need to move first. Cursor updates are throttled to about 100 ms.

## Workflow

1. `:Overleaf` — authenticate and select a project
2. File tree appears — press `Enter` to open a document
3. Edit normally — changes sync to Overleaf in real-time
4. `:w` — triggers compile and opens PDF
5. `:Overleaf tree` — switch between documents

## External Tool Integration (Claude Code, etc.)

By default, Overleaf documents exist only as virtual buffers — they have no files on disk. This means external tools like Claude Code cannot read or edit them.

Set `sync_dir` to enable local file mirroring:

```lua
require('overleaf').setup({
  sync_dir = '~/.overleaf',  -- or any directory
})
```

When connected to a project, all text documents are synced to `~/.overleaf/<project-name>/`. External tools can read and edit these files — changes are automatically detected and synced back to Overleaf.

### How it works

- **On connect**: all documents are fetched and written to disk
- **Neovim edits**: debounced writes keep disk files up to date
- **Remote edits**: disk files are updated when collaborators make changes
- **External edits**: file watchers detect changes and sync them to Overleaf via OT
  - For open documents: buffer is updated, triggering the normal OT pipeline
  - For closed documents: changes are sent directly via the bridge
  - Whole-file replacements from agents are supported, including multiline edits.
    Mirror writes import unseen disk changes before overwriting a file, and
    buffer consistency checks queue missed edits rather than reload over them.
- **On exit**: pending edits are flushed to Overleaf, mirrored to disk, and acknowledged before Overleaf buffers are removed from the editor session

### Commands

- `:Overleaf sync` — re-sync all documents (fetch from Overleaf and write to disk)
- `:Overleaf sync import` — import all external disk changes to Overleaf
- `:Overleaf sync export` — export all documents to disk

### Usage with Claude Code

```bash
# Start Claude Code in the sync directory
cd ~/.overleaf/My\ Project
claude
```

Claude Code can now read all your LaTeX files and make edits that sync back to Overleaf in real-time.

## How It Works

The plugin spawns a Node.js bridge process that connects to Overleaf's real-time collaboration server via Socket.IO. Edits in Neovim are converted to OT operations and sent to the server. Remote edits from other collaborators are transformed and applied to your buffer in real-time.

## Disclaimer

This is an **unofficial** plugin and is not affiliated with, endorsed by, or supported by [Overleaf](https://www.overleaf.com). It relies on Overleaf's internal real-time collaboration protocol, which is undocumented and may change at any time without notice. Such changes could cause the plugin to stop working, or in the worst case, lead to document corruption or data loss.

Overleaf maintains version history for all projects, so you can restore previous versions from the Overleaf web interface if anything goes wrong.

**Use this plugin at your own risk.** Always keep important work backed up.

## Acknowledgments

This project was developed with reference to the following projects for understanding Overleaf's real-time collaboration protocol:

- [AirLatex.vim](https://github.com/dmadisetti/AirLatex.vim) (MIT) — Neovim plugin for Overleaf by David Hartmann. Referenced for Chrome cookie extraction approach and Socket.IO connection patterns.
- [Overleaf-Workshop](https://github.com/iamhyc/Overleaf-Workshop) (AGPL-3.0) — VS Code extension for Overleaf. Referenced for protocol details including the v2 connection scheme, OT update hashing, and joinDoc parameters.

The code in this repository is an independent implementation in Lua/Node.js. No source code was directly copied from either project.

## License

MIT
