`kit/vendor/agepad/prepare-de-load-image.py` is adapted from
[chrissotraidis/agepad](https://github.com/chrissotraidis/agepad), commit
`c0f7cbdc69d8b1dca87a73a94490c3a65405762f` (MIT, copyright 2026 Chris Sotraidis).
Its license is retained beside the file. Upstream SHA-256:
`1b196c85f6c433b79bda2dfabab606e73d98f6baa177719e976a08a0738ea4c8`.

Local change: the standalone CLI rejects a manifest path equal to its source or
output binary, preventing accidental overwrite. Image conversion is unchanged.
Patched SHA-256:
`66b29b82adf8c8b152176e3434f0d370c68592360ff567db934771ffeff1ad0c`.

This toolkit contains no game binary, game assets, Steam binary, account tokens,
or signing credentials. Generated private staging files in `work/` must not be
redistributed. The UIKit display-mode adapter is also adapted from AgePad;
its attribution and MIT license are in `kit/compat/NOTICE.md`. The app-local Steam
semaphore compatibility implementation is based on AgePad's
`port/de/SysVSemaphoreCompat.h` at the same pinned commit; its attribution is
retained with the compatibility source and the upstream MIT license above.

The optional GL4ES build uses the MIT-licensed ptitSeb/gl4es repository at
`bc4314d8369f169d3fa81c5ed1b46b3dba4e74a5`. Its source and binaries are kept in
the private work directory; the reproducible builder and full license notice
are included in `kit/tools/build_gl4es.py` and `kit/compat/gl4es-notice.md`.

The optional mod sources in `kit/community/` implement iPad adaptations. Their
metadata credits the community work by daram2 and flover. Additional community
inputs, including illustration archives and the postmatch comment corpus, are
supplied by the buyer and processed locally. Game measurements used by the
optional mods are generated from that buyer's copy. Original mod distributions
and the game's stable Rust SDK are not bundled. See [mod sources and setup](docs/mods.md).

The upstream MIT notices apply to their identified components. Rights in
Teamfight Manager 2, Steam, Apple software, community mods and artwork remain
with their respective owners.
