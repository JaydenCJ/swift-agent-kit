# docs/

Assets referenced by the READMEs.

## `assets/demo.svg`

The terminal-style demo visual embedded at the top of `README.md`,
`README.zh.md` and `README.ja.md` (all three reference this same file).
It shows the offline demo command and its deterministic transcript — the
offline demo runs a scripted provider, so the output shown is fixed by
`Sources/swiftagentkit-demo/Demo.swift`. The footer inside the image says
so explicitly.

To replace it with a live terminal recording once you have a Swift
toolchain, record with [asciinema](https://asciinema.org) +
[agg](https://github.com/asciinema/agg):

```bash
asciinema rec demo.cast -c 'swift run swiftagentkit-demo --offline "What'"'"'s on my calendar tomorrow?"'
agg demo.cast docs/assets/demo.gif
```

then swap the `![Demo](docs/assets/demo.svg)` embed in all three READMEs
for `docs/assets/demo.gif` (keep the three files identical). Keep any GIF
under 15 seconds and 5 MB.
