# A window, a chart, zoom and pan. Nothing else.
#
#   make                        fills, lines, symbols from one .pmtiles
#   make TILE57=/path/to/tile57 adds the quilting compositor and the
#                               S-52 style/sprite/glyph engine
#   ./chartview <chart.pmtiles | directory-of-pmtiles>
#
# TILE57 is the checkout of the tile57 repository -- pass it explicitly;
# there is no default path, because there is no path that is right for
# everyone. Without it the app still runs, but it needs a style and a
# sprite sheet of its own and cannot quilt a chart library.

CHARTTABLE := ../..
ZIG        ?= zig
OPT        ?= ReleaseFast
# WebP tiles (elevation sources commonly serve them) need libwebp.
WEBP       ?= true
# libpng decodes about 1.6x faster than the built-in reader on a real tile.
LIBPNG     ?= true

CFLAGS  := -O2 -fobjc-arc -I$(CHARTTABLE)/include
LDFLAGS := -framework Cocoa -framework Metal -framework QuartzCore \
           -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers
ifeq ($(WEBP),true)
LDFLAGS += -L/opt/homebrew/lib -lwebp
endif
ifeq ($(LIBPNG),true)
LDFLAGS += -L/opt/homebrew/lib -lpng
endif
LIBS    := $(CHARTTABLE)/zig-out/lib/libcharttable.a

ifdef TILE57
CFLAGS += -DUSE_TILE57_COMPOSE -I$(TILE57)/include
LIBS   += $(TILE57)/zig-out/lib/libtile57.a
endif

.PHONY: all lib clean
all: chartview

# The static library the app links. Built here so `make` in this directory
# is the whole story.
lib:
	$(ZIG) build -Doptimize=$(OPT) -Dwebp=$(WEBP) -Dlibpng=$(LIBPNG) --build-file $(CHARTTABLE)/build.zig

chartview: main.m lib
	clang $(CFLAGS) main.m $(LIBS) $(LDFLAGS) -o $@

clean:
	rm -f chartview
