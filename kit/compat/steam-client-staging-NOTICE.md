# Private Steam client staging

`tools/stage_steam_client.py` stages only the eight binary paths and hashes recorded in `evidence/steam-engine-feasibility.json`. It does not load Steam code, start IPC, authenticate, read account/configuration files, or change the installed client. Private original copies, ARM64 slices, and metadata-retargeted images remain in a separate work directory. Missing frameworks and runtime API gaps are reported as work still required.

The script calls the existing pinned AgePad `prepare-de-load-image.py` adapter. Its upstream repository is [AgePad](https://github.com/chrissotraidis/agepad), pinned in this toolkit at `c0f7cbdc69d8b1dca87a73a94490c3a65405762f`; its MIT copyright and permission notice are included in `vendor/agepad/LICENSE`. Generated copies receive that adapter's ad-hoc signatures and must preserve every original vendor section. This is not profile signing or installation.

Steam client binaries belong to Valve and are supplied from the user's local installation. They are not included in this toolkit's deliverables. No AoE-specific Steam module, app813780 record, account state, or fabricated Steam response is reused. TFM2's app ID is 3009300; this staging step makes no ownership or sign-in claim.
