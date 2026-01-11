# faster-piper.yazi

A fast, cache-aware reimplementation of `piper.yazi` for Yazi.

`faster-piper` is a general-purpose previewer that pipes the output of an
arbitrary shell command into Yazi’s preview pane, with aggressive caching
and efficient scrolling for large outputs.

## Motivation

The original [`piper.yazi`](https://github.com/yazi-rs/plugins/tree/main/piper)
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
run = 'faster-piper -- CLICOLOR_FORCE=1 glow -w=$w -s=dark "$1"'
```

#### Example: Preview tarballs with `tar`

```toml
[[plugin.prepend_previewers]]
url = "*.tar*"
run = 'faster-piper --format=url -- tar tf "$1"'
```

### Fast scrolling and “jump to top/bottom”

`faster-piper` supports normal incremental scrolling via `seek +/-N` (in lines).

In addition, it implements a *jump heuristic* for very large seek steps:

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
