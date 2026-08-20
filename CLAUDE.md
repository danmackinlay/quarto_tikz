# tikz — a Quarto extension

One Lua filter, `_extensions/tikz/tikz.lua`, turning `.tikz` code blocks into
figures. The suites live in `tests/`; run them from the repo root with
`sh tests/run.sh`. They need only pandoc — no TeX distribution and no SVG
converter — so there is no excuse for landing a change without running them.

## Versioning: slow down

`_extensions/tikz/_extension.yml` carries the version, and it is what
`quarto add` / `quarto update` resolve. **Do not bump it as part of doing
work.**

The last *tagged* release is `v1.0.1`, from December 2024. The file currently
claims `1.7.0`. Every version in between was minted during a working session
and never tagged — four of them on 2026-08-20 alone, between 12:54 and 18:34.
So the numbers record how often someone felt like writing a new CHANGELOG
heading, not how many releases exist. Left alone, this reaches 1.28.0 within a
week and the version stops carrying any information at all.

The existing numbers stand; they are not worth rewriting. What changes is the
rate.

- **Default to not bumping.** Land the change and add it to the CHANGELOG under
  the heading that is already there. Bumping is a separate decision, and it is
  the user's to make — ask rather than assume.
- **One version per release, not one per change.** Several features and fixes
  share a version. If the current version has no tag, it has not shipped, so
  keep adding to it.
- **A minor bump means a user-visible feature actually shipped.** Refactors,
  internal consolidation, test work and documentation earn nothing, however
  large the diff.
- **A tag is what makes a version real.** If you are about to write a new
  `## X.Y.Z` heading while the previous one is untagged, you are renaming the
  unreleased version rather than creating a new one. Don't.
