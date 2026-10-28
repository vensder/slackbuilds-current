# SlackBuilds for Slackware-current

My SlackBuilds for packages Slackware-current doesn't ship, mostly audio
software, with the local changes needed to build them on -current
(GCC 16, CMake 4, Python 3.12, Qt5/Qt6).

- `alien/` - from Alien Bob: <http://www.slackware.com/~alien/slackbuilds/>
- `sbo/` - from SlackBuilds.org (target Slackware 15.0): <https://slackbuilds.org>

Helper scripts and guides are in the `slackware-notes` repo:
`download-slackbuilds.sh`, `build-slackbuild.sh`,
`README-alien-slackbuilds-scripts.md`, `README-sbo-custom-slackbuilds.md`.

Source tarballs and built packages are not stored here (see `.gitignore`).
SBo sources: URL and MD5 in `<name>.info`. Alien sources: downloaded by the
SlackBuild, except git snapshots (tarball only in Alien's build dir).

## Packages with local changes

| Package | Origin | Version | Local changes |
|---|---|---|---|
| fltk | sbo | 1.4.5 (SBo: 1.3.8) | doc globs `CHANGES* CREDITS* README*`; `rm -rf $PKG/usr/man/cat*` |
| stk | sbo | 5.0.1 (SBo: 4.4.4) | doc globs `INSTALL* README*` |
| lmms | sbo | 1.2.2 | CMake 4 seds (CMP0026, CMP0050, LOCATION); `$(pkg-config --cflags cairo)` in `SLKCFLAGS`; `#include "CarlaDefines.h"` in `plugins/carlabase/carla.h` |
| zynaddsubfx | alien | 3.0.6 | `patches/zynaddsubfx-3.0.6-mxml4.patch` (upstream PR #315, via Gentoo) for mxml 4 |
| qmmp | alien | 2.4.2 | `SRCURL` moved to `files/qmmp/${VERSION%.*}/` |
| carla | alien | 2.5.10 (Alien: 20241124 git snapshot) | stable release tarball from GitHub tag, renamed `carla-2.5.10.tar.gz`; built without MinGW-w64/wine |

## Packages built as-is

| Package | Origin | Version | Notes |
|---|---|---|---|
| vmpk | alien | 0.9.2 | `-V 0.9.2` |
| x42-plugins | alien | 20260908 | `-n` |
| lsp-plugins | alien | 1.2.35 | `-n`; `MAKEFLAGS=-s` for less output |
| mxml | alien | 4.0.6 | `-n`; needs the zynaddsubfx mxml4 patch |
| libgig | alien | 4.6.0 | |
| portaudio | alien | 190700_20210406 | |
| jack2, liblo, libltc, zita-convolver, lv2, serd, sord, zix | alien | | dependencies |

## Not built

| Package | Reason |
|---|---|
| MinGW-w64 | GCC 13.1 toolchain doesn't build with GCC 16 (see SBo guide case study); only needed for carla's Windows plugin bridge |

## Build commands

```
# Alien (from this repo)
export SBDIR=~/git/slackbuilds-current/alien
su -c "SBDIR=$SBDIR ./build-slackbuild.sh -q -i <package>"

# lmms (SBo)
cd ~/git/slackbuilds-current/sbo/lmms
su -c 'NUMJOBS=-j$(nproc) CMAKE_POLICY_VERSION_MINIMUM=3.5 sh ./lmms.SlackBuild 2>&1 | tee build.log'
```

Order for lmms: fltk, stk, libgig, portaudio, carla, then lmms.

## Workflow

1. Import the upstream SlackBuild unchanged, commit: `import <pkg> from alien|sbo`.
2. Make the fixes, commit separately with the reason in the message,
   so `git log -p <path>` shows exactly what changed against upstream.
3. Update the tables above.
4. When upstream updates a SlackBuild, download it over the repo copy and
   use `git diff` to merge the local changes back.
