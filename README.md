# SlackBuilds for Slackware-current

My SlackBuilds for packages Slackware-current doesn't ship, mostly audio
software, with the local changes needed to build them on -current
(GCC 16, CMake 4, Python 3.12, Qt5/Qt6).

- `vensder/` - my own SlackBuilds (rewrites of alien/sbo ones), build tag `vensder`
- `alien/` - from Alien Bob: <http://www.slackware.com/~alien/slackbuilds/>
- `sbo/` - from SlackBuilds.org (target Slackware 15.0): <https://slackbuilds.org>

## Scripts

Run from the repo; `-t` picks the tree (`alien` is the default):

```
# download a SlackBuild and its dependencies (alien or sbo)
scripts/download-slackbuilds.sh amsynth
scripts/download-slackbuilds.sh -t sbo yoshimi

# check versions (no root needed), then build and install
scripts/build-slackbuild.sh -t sbo -c yoshimi
su -c 'scripts/build-slackbuild.sh -t sbo -i -V 2.3.6.5 yoshimi'
su -c 'scripts/build-slackbuild.sh -t vensder -i calf'
```

- `build-slackbuild.sh -t sbo` downloads missing sources from `DOWNLOAD` in
  `<name>.info` (MD5 checked only for the `.info` version) and reads
  dependencies from `REQUIRES` (SBo names mapped to local ones via
  `sbo/.aliases`, e.g. `jack jack2`). With `-d`, dependencies are searched in the
  selected tree first, then in `vensder`, `alien`, `sbo`.
- `-a` works on installed packages with the tree's tag (`alien`, `vensder`,
  `_SBo`). Hold list: `<tree>/.hold`.
- `download-slackbuilds.sh -t sbo` keeps an existing `sbo/<name>` dir (local
  changes); remove it to download again. Installed dependencies and ones
  already in `alien/` or `vensder/` are skipped.
- `scripts/check-official-overlap.sh` lists installed third-party packages
  that Slackware now ships.
- `scripts/check-rebuild.sh` (after `slackpkg upgrade-all`, no root needed)
  lists installed `alien`, `vensder` and `_SBo` packages that need a rebuild:
  `BROKEN` = ldd reports a library "not found" and no file of that name is
  in /lib64, /usr/lib64 or /opt (soname bump, e.g. poppler);
  with `-u` also `UPDATED` = a directly linked library comes from a package
  installed or upgraded after this one (rebuild optional; glibc/gcc ignored,
  `IGNORE_DEPS=...`). Prints the `build-slackbuild.sh -f -i` commands; exit
  status 1 if something needs a rebuild. `-t tree` limits it to one tree,
  names limit it to those packages (`scripts/check-rebuild.sh okular`).
- `scripts/kernel-update.sh -c` lists installed kernel-generic versions,
  checks the mirror for a newer one and prints recommended custom GRUB entries
  (newest via `/boot/vmlinuz` + `/boot/initrd.gz`, older ones versioned).
  Without `-c` (as root: `su -c 'scripts/kernel-update.sh'`) it downloads,
  checks md5 + gpg and `installpkg`s the newer kernel after confirmation.
  `-c` also shows `dmesg --level=err,warn` (via sudo or su -c if needed).
  `su -c 'scripts/kernel-update.sh -d'` removes kernels older than the newest
  two after confirmation: only with more than two installed and the newest one
  running; Slackware 15.0 kernels (`vmlinuz-generic-VER`) are left alone.
  It asks: remove all, one by one, or nothing; `-d 7.2.11 7.2.12` offers only
  those versions.
  Steps: `README-slackware-current-kernel-update.md` in `slackware-notes`.
- `scripts/clean-build.sh` shows free disk space and the size of build
  leftovers: `/tmp/build/*` (alien, vensder), `/tmp/SBo/*` (sbo) and
  Slackware-style `/tmp/package-*` and `/tmp/<pkg>-<ver>` dirs (`<pkg>` = a
  SlackBuild in this repo). Dry run by default; `su -c 'scripts/clean-build.sh -y'`
  deletes them (refused while a SlackBuild is running). `-p` adds built
  packages in `/tmp` that are installed or have another version installed,
  and build logs. Nothing else in `/tmp` is touched.
  `build-slackbuild.sh -C` removes a package's build dirs right after a
  successful build (kept on failure for debugging).

Guides are in the `slackware-notes` repo:
`README-alien-slackbuilds-scripts.md`, `README-sbo-custom-slackbuilds.md`.

Source tarballs and built packages are not stored here (see `.gitignore`).
SBo sources: URL and MD5 in `<name>.info`. Alien sources: downloaded by the
SlackBuild, except git snapshots (tarball only in Alien's build dir).

## Packages with local changes

| Package | Origin | Version | Local changes |
|---|---|---|---|
| fltk | sbo | 1.4.5 (SBo: 1.3.8) | doc globs `CHANGES* CREDITS* README*`; `rm -rf $PKG/usr/man/cat*` |
| stk | sbo | 5.0.1 (SBo: 4.4.4) | doc globs `INSTALL* README*` |
| lmms | sbo | 1.2.2 | `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`; CMake 4 seds (CMP0026, CMP0050, LOCATION); `$(pkg-config --cflags cairo)` in `SLKCFLAGS`; `#include "CarlaDefines.h"` in `plugins/carlabase/carla.h` |
| yoshimi | sbo | 2.3.6.5 (SBo: 2.3.2) | top dir `${PRGNAM}_$VERSION`; doc glob `README*` |
| zynaddsubfx | alien | 3.0.6 | `patches/zynaddsubfx-3.0.6-mxml4.patch` (upstream PR #315, via Gentoo) for mxml 4 |
| qmmp | alien | 2.4.2 | `SRCURL` moved to `files/qmmp/${VERSION%.*}/` |
| carla | alien | 2.5.10 (Alien: 20241124 git snapshot) | default `VERSION=2.5.10`, `SRCURL` = GitHub tag tarball `v$VERSION` (saved as `carla-2.5.10.tar.gz`), git snapshot only for `VERSION=*git`/`HEAD`; built without MinGW-w64/wine |
| surge-xt | alien | 1.3.4 | -DSURGE_SKIP_WERROR=ON (bundled LuaJIT/sqlite warnings break -Werror on GCC 16) |
| calf | vensder | 0.90.9 (Alien: autotools build) | CMake build from GitHub tag tarball; seds for PKGDOCDIR (`config.h.cmake.in`) and gtk.rc `pixmap_path` (`gui/CMakeLists.txt`); `alien/calf` kept unchanged |
| vaporizer2 | vensder | 3.5.0 (new) | GitHub tag tarball + 6 submodule tarballs at the commits pinned by the tag (`*_COMMIT` vars); LV2/VST3/CLAP in `/usr/lib64/{lv2,vst3,clap}`, data in `/usr/share/Vaporizer2`; `BUILD_AVX=OFF` for non-AVX CPUs. Carla-Rack in Reaper: `ln -s /usr/lib64/lv2/VASTvaporizer2.lv2 ~/.lv2/` |
| helm-synth | vensder | 0.10.0 (Alien: 0.9.0) | JUCE CMake build of the bepzi/helm fork, from tag `v0.10.0` in vensder/helm; no LTO (GCC 16 loses `createPluginFilter()` in the LV2 link); standalone as `/usr/bin/helm-synth`, LV2/VST3 in `/usr/lib64/{lv2,vst3}`, presets in `/usr/share/helm/patches`; `alien/helm-synth` kept unchanged. Carla-Rack in Reaper: `ln -s /usr/lib64/lv2/helm.lv2 ~/.lv2/` |
| dexed | vensder | 1.1.0 (new) | GitHub tag tarball + 7 submodule tarballs at the commits pinned by the tag (`*_COMMIT` vars); seds in `source/CMakeLists.txt`: no LTO, add LV2 format, no copy into `~/.vst3`, JACK on (upstream `find_package(Jack)` never finds it); standalone `/usr/bin/Dexed`, LV2/VST3/CLAP in `/usr/lib64/{lv2,vst3,clap}`. Carla-Rack in Reaper: `ln -s /usr/lib64/lv2/Dexed.lv2 ~/.lv2/` |
| sq8l | vensder | 1.0.0_beta.3 (new) | `VERSION` is the git tag as-is (default `v1.0.0-beta.3`, or `VERSION=nightly`); the tag is cloned with `--recursive` and packed into `SQ8L-<tag>.tar.gz` (GitHub tag tarballs lack the submodules); package version 1.0.0_beta.3 or nightly_<commit date>; delete `SQ8L-nightly.tar.gz` to fetch a newer nightly; git needed; LV2/VST2/VST3/CLAP in `/usr/lib64/{lv2,vst,vst3,clap}`, no standalone. Carla-Rack in Reaper: `ln -s /usr/lib64/lv2/SQ8L.lv2 ~/.lv2/` |
| adlplug | vensder | 1.0.2 (new) | the tag `v1.0.2` is cloned with `--recursive` and packed into `ADLplug-1.0.2.tar.gz` (GitHub tag tarballs lack the submodules); git needed; sed drops `JUCE_PACKED` in the bundled JUCE 5.4 `juce_PixelFormats.h` (GCC: "cannot bind packed field"); `CMAKE_POLICY_VERSION_MINIMUM=3.5`; builds both chips: ADLplug (OPL3) and OPNplug (OPN2) as JACK standalones `/usr/bin/{ADLplug,OPNplug}`, LV2/VST2 in `/usr/lib64/{lv2,vst}` (no VST3 on Linux upstream). Carla-Rack in Reaper: `ln -s /usr/lib64/lv2/ADLplug.lv2 /usr/lib64/lv2/OPNplug.lv2 ~/.lv2/` |
| adlplug-next | vensder | 2.1.0_nightly20261108 (new) | `VERSION` is the git tag as-is (default and only tag `nightly`); cloned with the top-level submodules only (MediaPerch's own are not needed, one is not on GitHub) and packed with the `.git` dirs into `ADLplug-Next-nightly.tar.gz` (configure applies `patches/` to the submodules with git); delete it to fetch a newer nightly; upstream presets `adl-release`/`opn-release` (Clang, LLD, Ninja, ThinLTO, PGO, AVX2; needs cmake >= 3.29, llvm, ninja, git, an AVX2 CPU); `ADLplug_WERROR=OFF`; sed adds `JUCE_JACK=1`; standalones `/usr/bin/{ADLplug-Next,OPNplug-Next}`, LV2/VST3 in `/usr/lib64/{lv2,vst3}`. Carla-Rack in Reaper: `ln -s /usr/lib64/lv2/ADLplug-Next.lv2 /usr/lib64/lv2/OPNplug-Next.lv2 ~/.lv2/` |
| zyn-fusion | vensder | 3.0.6 (Alien: 3.0.5) | zynaddsubfx 3.0.6 with `GuiModule=zest` plus the official `zyn-fusion-ui-src-3.0.6.tar.bz2` (mruby-zest UI, submodules included), both from SourceForge; patches from `alien/zynaddsubfx` (cstdint, mxml 4); `CMAKE_POLICY_VERSION_MINIMUM=3.5`; needs ruby (rake) and libuv to build; UI in `/opt/zyn-fusion` (zynaddsubfx and the plugin UI look there), `/usr/bin/zyn-fusion` symlink; LV2/VST in `/usr/lib64/{lv2,vst}`; replaces the zynaddsubfx package (same files): `upgradepkg zynaddsubfx%zyn-fusion-*.txz`; `alien/zyn-fusion` kept unchanged. Carla-Rack in Reaper: `ln -s /usr/lib64/lv2/ZynAddSubFX.lv2 ~/.lv2/` |
| discount | vensder | 3.0.2.0 (new) | GitHub tag tarball; SBo options without `--with-amalloc` (debug allocator), plus `--pkg-config` (`libmarkdown.pc`, needed by okular); dependency of vensder/okular |
| okular | vensder | 26.08.3 (Slackware: 26.08.3) | Slackware's cmake options (kde.options + cmake/okular) without `-DFORCE_NOT_REQUIRED_DEPENDENCIES=Discount`, so the Markdown generator is built against discount (stock okular shows `.md` as plain text); KDE Gear tarball from download.kde.org; `VERSION` must match the installed KDE Gear; rebuild after KDE Gear, KF6 or poppler updates; `okular` is in `/etc/slackpkg/blacklist` |
| raptor2 | alien | 2.0.16 | added SRCURL (download.librdf.org) and a wget step for the missing tarball |
| vamp-plugin-sdk | alien | 2.10.0 | SRCURL moved to GitHub release vamp-plugin-sdk-v${VERSION%.0} (code.soundsoftware.ac.uk is down) |
| serd | alien | 0.32.10 (Alien: 0.32.2) | -Ddocs=disabled (sphinxygen AssertionError on doc/api/serd.rst) |
| sonic-visualiser | alien | 5.2.1 (Alien: 4.5.2) | patches/sonic-visualiser-5.2.1_qt6.11.patch (upstream svcore 2dee776, svgui d5dccf3) for Qt 6.11; menu PNG via rsvg-convert (IM7 SVG policy) |

## Packages built as-is

Version = installed version; `-n` = newest upstream, `-V` = given version.

| Package | Origin | Version | Notes |
|---|---|---|---|
| alsa-plugins-jack | alien | 1.2.12 | |
| amsynth | alien | 2.0.0 | |
| drumstick | alien | 2.11.1 | dependency of vmpk |
| dssi | alien | 1.1.1 | |
| faad2 | alien | 2.11.4 | dependency of qmmp |
| helm-synth | alien | 0.9.0 | superseded by vensder/helm-synth |
| jack-example-tools | alien | 4 | |
| jack2 | alien | 1.9.22 | |
| ladspa_sdk | alien | 1.17 | |
| libgig | alien | 4.6.0 | for lmms GIG player |
| liblo | alien | 0.36 | `-n` |
| libltc | alien | 1.3.2 | dependency of x42-plugins |
| lsp-plugins | alien | 1.2.35 | `-n`; `MAKEFLAGS=-s` for less output |
| lv2 | alien | 1.18.10 | |
| mxml | alien | 4.0.6 | `-n`; needs the zynaddsubfx mxml4 patch |
| ntk | alien | 1.3.1001 | |
| portaudio | alien | 190700_20210406 | for lmms |
| qpwgraph | alien | 1.0.4 | |
| serd | alien | 0.32.10 | `-n` (SlackBuild: 0.32.2) |
| sonivox | alien | 4.0.2 | `-n` |
| sord | alien | 0.16.22 | `-n` (SlackBuild: 0.16.16) |
| vmpk | alien | 0.9.2 | `-V 0.9.2` |
| x42-plugins | alien | 20260908 | `-n` |
| zita-alsa-pcmi | alien | 0.6.1 | |
| zita-convolver | alien | 4.0.3 | dependency of x42-plugins |
| zita-resampler | alien | 1.11.2 | |
| zix | alien | 0.8.2 | `-n` (SlackBuild: 0.4.2) |

## Not built

| Package | Reason |
|---|---|
| MinGW-w64 | GCC 13.1 toolchain doesn't build with GCC 16 (see SBo guide case study); only needed for carla's Windows plugin bridge. SlackBuild has partial fixes |
| wine, FAudio | optional carla dependencies (Windows plugin bridge) |
| python-pyliblo | optional carla dependency (OSC remote control) |
| jack_capture, meterbridge | downloaded, not built yet |

## Build commands

```
# Alien (from this repo)
export SBDIR=~/git/slackbuilds-current/alien
su -c "SBDIR=$SBDIR ./build-slackbuild.sh -q -i <package>"

# lmms (SBo)
cd ~/git/slackbuilds-current/sbo/lmms
su -c 'NUMJOBS=-j$(nproc) CMAKE_POLICY_VERSION_MINIMUM=3.5 sh ./lmms.SlackBuild 2>&1 | tee build.log'

# vensder (from this repo)
export SBDIR=~/git/slackbuilds-current/vensder
su -c "SBDIR=$SBDIR PKGTAG=vensder ./build-slackbuild.sh -q -i <package>"
```

Order for lmms: fltk, stk, libgig, portaudio, carla, then lmms.

`alien/.hold` lists packages that `build-slackbuild.sh -a` and `-d` must not
rebuild (one name per line, `#` comments).

## Workflow

1. Import the upstream SlackBuild unchanged, commit: `import <pkg> from alien|sbo`.
2. Make the fixes, commit separately with the reason in the message,
   so `git log -p <path>` shows exactly what changed against upstream.
3. Update the tables above.
4. When upstream updates a SlackBuild, download it over the repo copy and
   use `git diff` to merge the local changes back.
