# faster-piper.yazi

A fast, cache-aware reimplementation of `piper.yazi` for Yazi.

`faster-piper` is a general-purpose previewer that pipes the output of an
arbitrary shell command into Yazi’s preview pane, with aggressive caching
and efficient scrolling for large outputs.

## Installation

```sh
ya pkg add alberti42/faster-piper
```

## Motivation

The original [`piper.yazi`](https://github.com/yazi-rs/plugins/tree/main/piper.yazi)
is a simple and elegant previewer that executes a shell command on each preview.

`faster-piper` started as an experiment to explore whether:

- preview output could be cached safely,
- scrolling could be made O(1) using file-backed paging,
- large outputs could be handled without re-running the generator,
- resizing and jump-to-end behavior could be made deterministic.

The result is a substantially different internal architecture that favors
performance and predictability for expensive preview commands.

## Compatibility with `piper.yazi`

`faster-piper` is **syntax-compatible** with `piper.yazi`.

Existing configurations written for `piper.yazi` continue to work without
modification. The command format, variables, and preview semantics are the same:

- `$1` — path to the file being previewed
- `$w` — preview width
- `$h` — preview height

You can replace `piper` with `faster-piper` in your Yazi configuration and keep
using the same preview commands.

For more usage examples and ideas, please refer to the original
[`piper.yazi` README](https://github.com/yazi-rs/plugins/tree/main/piper).

## Usage

### Configure previewers

Use `faster-piper` exactly like `piper`: pass a shell command after `--`.
The command’s stdout becomes the preview content.

#### Example: Preview Markdown with `glow`

```toml
[[plugin.prepend_previewers]]
url = "*.md"
run = 'faster-piper -- CLICOLOR_FORCE=1 glow -w=$w -s=dracula -- "$1"'
```

#### Example: Preview tarballs with `tar`

```toml
[[plugin.prepend_previewers]]
url = "*.tar*"
run = 'faster-piper --format=url -- tar tf "$1"'
```

### Preloading for instant previews

`faster-piper` works **without** preloading: the first `peek` will generate the
cache on demand.

If you want previews to appear _instantaneously_ when you move the cursor (i.e.
the cache is already warm by the time `peek` runs), configure a matching rule
under `plugin.prepend_preloaders`.

There are two supported ways to do this:

#### Option A (recommended): define the command only in the preloader with `--rely-on-preloader`

If you don’t want to duplicate the piping command in both places, you can make
the previewer rule “rely on the preloader”:

- The **preloader** is responsible for generating the cache (and therefore must
  include the command after `--`).
- The **previewer** becomes a lightweight reader: it only displays the cache and
  (in edge cases such as terminal resize) may self-heal using the cached recipe.

Example:

```toml
[plugin]
prepend_previewers = [
  { url = "*.md",     run = 'faster-piper --rely-on-preloader' },
  { url = "*.tar*",   run = 'faster-piper --rely-on-preloader --format=url' },
  { url = "*.txt.gz", run = 'faster-piper --rely-on-preloader' },
]

prepend_preloaders = [
  { url = "*.md",     run = 'faster-piper -- CLICOLOR_FORCE=1 glow -w=$w -s=dracula -- "$1"' },
  { url = "*.tar*",   run = 'faster-piper -- tar tf "$1"' },
  { url = "*.txt.gz", run = 'faster-piper -- gzip -dc "$1"' },
]
```

This mode is mainly about **avoiding duplication**: you keep the generator
command in one place (the preloader rule), while the previewer rule stays a
lightweight cache reader.

Note: `faster-piper` is race-safe in both modes — if `preload` and `peek` happen
at the same time, a lock ensures only one process writes the cache, and the
other will reuse it once it becomes available.

##### Notes on `--rely-on-preloader`

- `--rely-on-preloader` is intended for setups where you **do configure**
  `prepend_preloaders`. In that mode, `peek` will first assume the cache was
  warmed by the preloader, and only falls back to self-healing in edge cases
  (e.g. resize-triggered peeks).
- If you **don’t** use preloaders at all, omit the flag and run in normal mode:
  `peek` will generate the cache on demand.
- When you _do_ use preloaders, `--rely-on-preloader` is the simplest way to
  avoid keeping two command strings in sync.
- If you choose Option B (duplicating commands), keep them **identical**;
  mixing different commands for the same matcher is undefined because of races.

#### Option B (classic): duplicate the same command in previewers + preloaders

This mirrors `piper.yazi` usage and is always valid.

```toml
[plugin]
prepend_previewers = [
  { url = "*.md",     run = 'faster-piper -- CLICOLOR_FORCE=1 glow -w=$w -s=dracula -- "$1"' },
  { url = "*.tar*",   run = 'faster-piper --format=url -- tar tf "$1"' },
  { url = "*.txt.gz", run = 'faster-piper -- gzip -dc "$1"' },
]

prepend_preloaders = [
  { url = "*.md",     run = 'faster-piper -- CLICOLOR_FORCE=1 glow -w=$w -s=dracula -- "$1"' },
  { url = "*.tar*",   run = 'faster-piper -- tar tf "$1"' },
  { url = "*.txt.gz", run = 'faster-piper -- gzip -dc "$1"' },
]
```

**Important:** the command templates must be identical. Yazi may race `preload`
and `peek`, and whichever runs first might win. If the commands differ, the cache
content becomes ambiguous.

##### Notes on race conditions (preloader vs. peek)

`faster-piper` handles the race between preloading and previewing gracefully:

- If both `preload` and `peek` arrive around the same time, **the generator is
  not run twice** (the lock ensures only one writer).
- Which one “wins” (preloader or peek) can fluctuate depending on timing, but
  the outcome is the same: you get a valid cache and a correct preview.

### Fast scrolling and “jump to top/bottom”

`faster-piper` supports normal incremental scrolling via `seek +/-N` (in lines).

In addition, it implements a _jump heuristic_ for very large seek steps:

- If a single `seek` step is **less than -999**, it jumps to the **top**.
- If a single `seek` step is **greater than +999**, it jumps to the **bottom**.

This is useful for binding keys like Home/End to instant top/bottom navigation,
without having to know the total line count ahead of time.

### Recommended keymaps

Add these to your `prepend_keymap` to enable smooth scrolling in the preview:

```toml
[plugin]
prepend_keymap = [
  { on = "<A-Up>",       run = "seek -1",      desc = "Scroll up" },
  { on = "<A-Down>",     run = "seek +1",      desc = "Scroll down" },
  { on = "<A-PageUp>",   run = "seek -15",     desc = "Scroll page up" },
  { on = "<A-PageDown>", run = "seek +15",     desc = "Scroll page down" },
  { on = "<A-Home>",     run = "seek -10000",  desc = "Scroll to the top" },
  { on = "<A-End>",      run = "seek +10000",  desc = "Scroll to the bottom" },
]
```

Tip: if you prefer different thresholds, just keep the “jump” bindings beyond
±999 (e.g. ±5000, ±10000).

## Relationship to `piper.yazi`

This project is a **from-scratch rewrite** inspired by the original idea of
`piper.yazi`.

- The core concept (using shell commands as previewers) comes from
  `piper.yazi`.
- The configuration syntax and user-facing behavior are intentionally kept
  compatible.
- The internal implementation, caching model, and scrolling logic are new and
  optimized for performance.

All credit for the original idea and initial implementation goes to the
`piper.yazi` authors.

## License

This project is licensed under the MIT License.

It is inspired by `piper.yazi`, which is also MIT-licensed.
See the LICENSE file for details.
