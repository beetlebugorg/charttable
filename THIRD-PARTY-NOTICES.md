# Third-party notices

charttable is a clean-room implementation of the published MapLibre Style
Specification (https://maplibre.org/maplibre-style-spec/). Its code derives
from two sources owned by this project's author: the lookout-core rendering
engine and the tile57 chart engine. No MapLibre source code is used in, or
was consulted for, the implementation, with the single disclosed exception
below.

One third-party component is used deliberately and under its own license:
mapbox/earcut, ported for polygon triangulation. It is not part of
MapLibre.

## mapbox/earcut — polygon triangulation (ISC)

`src/layout/earcut.zig` is a PORT of earcut.js from
https://github.com/mapbox/earcut, not an independent implementation. It
follows that library's structure and algorithms function for function:
linked-list rings, David Eberly's hole-bridge search, the z-order hash that
bounds the ear test, and the three-stage recovery when ear slicing stalls
(filter collinear points, cure local self-intersections, split on a
diagonal). The source was read on 2026-08-12 and ported deliberately.

It replaced charttable's own ear clipper, which assumed a simple polygon
and fanned the remainder when it ran out of ears — laying triangles outside
the polygon. Measured over 616 real chart fills, 16 painted over their
neighbours before the port and 1 after.

Two departures, both about size rather than behaviour: the hole-bridge
search scans the ring instead of earcut's block-bbox index (whose own
comments note it can pick a different, equally valid bridge), and the
z-order index sorts an array rather than merge-sorting the list in place.

earcut is ISC licensed. Its license, in full:

```
ISC License

Copyright (c) 2026, Mapbox

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```

## Disclosure: maplibre-native-ffi (read during pre-design reconnaissance)

On 2026-08-12, before the clean-room policy for this project was set, an
automated survey of related local checkouts read the following from a
checkout of https://github.com/maplibre/maplibre-native-ffi (commit 6e72fca)
while orienting on a prior integration experiment:

- `README.md` (in full)
- `examples/zig-readback/main.zig` (first 30 lines, plus grep-matched lines)
- `build.zig` (10 grep-matched lines)
- `include/maplibre_native_c/runtime.h` (~18 grep-matched lines around the
  resource-provider declarations)
- `include/maplibre_native_c/surface.h`, `render_target.h`,
  `render_session.h`, `texture.h` (extracted symbol names only)
- `CMakePresets.json` (preset name strings only)

No C++ implementation sources (`src/`, `third_party/`, `cmake/`) were read.
None of the material above is incorporated in charttable, and the survey
findings derived from it were excluded from charttable's design inputs. It is
acknowledged here, with the project's license reproduced below, because it
was read at all.

### maplibre-native-ffi license

```
BSD 2-Clause License

Copyright (c) 2026, MapLibre contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Vendored: MapLibre style-spec conformance test fixtures

`test/spec/expression/` contains the expression integration-test fixtures
(JSON test data) from https://github.com/maplibre/maplibre-style-spec at
commit `d881eef3be6a3602ff3434e1d9a20067b3fe1a31`, vendored 2026-08-12 as
charttable's conformance oracle. These are test *data*, run against
charttable's independent implementation; no implementation code from that
repository is used. The repository's license (BSD-3-Clause, plus the
additional notices it bundles) is reproduced in full at
`test/spec/LICENSE.txt` and applies to the vendored fixtures.

## Ongoing policy

Any future reading or use of MapLibre source code (maplibre-native,
maplibre-native-ffi, maplibre-gl-js, the maplibre-style-spec repository
including its reference JSON and test fixtures) must be recorded in this
file with the relevant license text. Implementing from the published
specification pages does not require a notice; vendoring or consulting
repository files does.
