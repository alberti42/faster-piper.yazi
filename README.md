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

### Example: Preview Markdown with `glow`

```toml
[[plugin.prepend_previewers]]
url = "*.md"
run = 'faster-piper -- CLICOLOR_FORCE=1 glow -w=$w -s=dark "$1"'
```

### Example: Preview tarballs with `tar`

```toml
[[plugin.prepend_previewers]]
url = "*.tar*"
run = 'faster-piper --format=url -- tar tf "$1"'
```

For more usage examples and ideas, please refer to the original
[`piper.yazi` README](https://github.com/yazi-rs/plugins/tree/main/piper).

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
