// chartview — the smallest macOS app that puts a charttable map on screen.
//
// A window, a CAMetalLayer, and the C ABI. No nib, no storyboard, no app
// delegate ceremony beyond what AppKit insists on.
//
//   cc -fobjc-arc -I include examples/macos/main.m zig-out/lib/libcharttable.a \
//      -framework Cocoa -framework Metal -framework QuartzCore -o chartview
//   ./chartview [chart.pmtiles | ENC_ROOT dir] [style.json]
//
// Drag to pan, flick to throw it; scroll or pinch to zoom (lookout-marine's
// rule: scroll is always zoom, drag is always pan). +/- and arrows too.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UTCoreTypes.h>
#include <charttable.h>
#ifdef USE_TILE57_COMPOSE
#include <tile57.h>
#endif
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <objc/runtime.h>

static NSData *readFile(NSString *path) {
    return path ? [NSData dataWithContentsOfFile:path] : nil;
}

// Optional: the sprite sheet and glyph ranges, so symbol layers draw. Baked
// by `tile57 sprite-mln -o DIR` and `tile57 emit-glyphs -o DIR`; point
// CHARTTABLE_SPRITE_DIR / CHARTTABLE_GLYPHS_DIR at them. Without a sprite
// the plain (fills + lines) style is used instead.
static BOOL loadSprite(charttable *m, NSString *dir) {
    if (!dir) return NO;
    NSData *json = readFile([dir stringByAppendingPathComponent:@"sprite-mln.json"]);
    NSData *png = readFile([dir stringByAppendingPathComponent:@"sprite-mln.png"]);
    if (!json || !png) return NO;
    return charttable_set_sprite(m, json.bytes, json.length, png.bytes, png.length) == CHARTTABLE_OK;
}

static void loadGlyphs(charttable *m, NSString *dir) {
    if (!dir) return;
    for (NSString *range in @[ @"0-255", @"256-511" ]) {
        NSString *p = [NSString stringWithFormat:@"%@/Noto Sans Regular/%@.pbf", dir, range];
        NSData *pbf = readFile(p);
        if (pbf) charttable_add_glyphs(m, pbf.bytes, pbf.length);
    }
}

// ---- mariner settings ------------------------------------------------------
//
// tile57 emits this style as a TEMPLATE: no display filters baked in, because
// the client is expected to gate them live (src/style/maplibre.zig, Options
// .mariner = null). So "mariner settings" here means transforming the style
// before it is loaded, exactly the way tile57's own style builder would have.
// The clauses below are lifted from tile57 src/style/mariner.zig so the two
// agree on what each setting means.

static id jarr(NSArray *a) { return a; }

/// Declare the tile encoding on every vector source (the spec's `encoding`
/// field, which charttable dispatches its decoder on).
/// Admit display category 2 (OTHER) on the SOUNDING layers only.
///
/// The mariner's `soundings` switch is documented as independent of the
/// display category -- "every ECDIS gives soundings their own switch and the
/// everyday setting is STANDARD + soundings ON". In this engine build it
/// only flips the layers' `visibility`, while the category clause the common
/// filters AND on still drops SOUNDG (category 2). The layers end up visible
/// and empty. Widening the category list on those two layers gives the
/// documented behavior without turning on the rest of OTHER (the seabed
/// labels, the cables, the low-priority clutter).
static id widenSoundingCategory(id node) {
    if (![node isKindOfClass:NSArray.class]) return node;
    NSArray *a = node;
    // ["in", <category expr>, ["literal", [...]]]
    if (a.count == 3 && [a[0] isEqual:@"in"] &&
        [a[2] isKindOfClass:NSArray.class] && [a[2][0] isEqual:@"literal"] &&
        [NSJSONSerialization isValidJSONObject:@[a[1]]] &&
        [[NSString stringWithFormat:@"%@", a[1]] containsString:@"display_category"]) {
        NSArray *vals = a[2][1];
        if (![vals containsObject:@2]) {
            NSMutableArray *wider = [vals mutableCopy];
            [wider addObject:@2];
            return @[ a[0], a[1], @[ @"literal", wider ] ];
        }
        return node;
    }
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:a.count];
    for (id c in a) [out addObject:widenSoundingCategory(c)];
    return out;
}

static NSData *soundingsIndependentOfCategory(NSData *styleJson) {
    NSMutableDictionary *style =
        [NSJSONSerialization JSONObjectWithData:styleJson
                                        options:NSJSONReadingMutableContainers
                                          error:nil];
    if (!style) return styleJson;
    int touched = 0;
    for (NSMutableDictionary *l in style[@"layers"]) {
        if (![l[@"source-layer"] isEqualToString:@"soundings"]) continue;
        if (!l[@"filter"]) continue;
        l[@"filter"] = widenSoundingCategory(l[@"filter"]);
        touched++;
    }
    NSLog(@"soundings: category widened on %d layers", touched);
    return [NSJSONSerialization dataWithJSONObject:style options:0 error:nil] ?: styleJson;
}

static NSData *stampEncoding(NSData *styleJson, NSString *encoding) {
    NSMutableDictionary *style =
        [NSJSONSerialization JSONObjectWithData:styleJson
                                        options:NSJSONReadingMutableContainers
                                          error:nil];
    if (!style) return styleJson;
    NSMutableDictionary *sources = style[@"sources"];
    for (NSString *name in sources) {
        NSMutableDictionary *src = sources[name];
        if ([src[@"type"] isEqualToString:@"vector"]) src[@"encoding"] = encoding;
    }
    return [NSJSONSerialization dataWithJSONObject:style options:0 error:nil] ?: styleJson;
}

/// AND a clause onto a layer's filter, whatever it already had.
static void andFilter(NSMutableDictionary *layer, id clause) {
    id existing = layer[@"filter"];
    layer[@"filter"] = existing ? jarr(@[ @"all", existing, clause ]) : clause;
}

/// Rewrite the depth-band thresholds inside a fill-color expression.
/// tile57 bakes the mariner's contours in as literals (shallow / safety /
/// deep, meters), so changing them is a substitution on that subtree.
static id rewriteContours(id node, double from, double to) {
    if ([node isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[node count]];
        for (id child in (NSArray *)node) [out addObject:rewriteContours(child, from, to)];
        return out;
    }
    if ([node isKindOfClass:NSNumber.class] && ![node isKindOfClass:objc_getClass("__NSCFBoolean")]) {
        if (fabs([node doubleValue] - from) < 1e-9) return @(to);
    }
    return node;
}

typedef struct {
    /// The composed tiles arrive as raw MLT, so the source must say so --
    /// charttable picks its decoder from the spec's `encoding` field, and a
    /// vector source that omits it means MVT.
    BOOL mlt_source;
    BOOL data_quality;         // M_QUAL seabed-quality overlay
    BOOL show_inform_callouts; // the [i] INFORM01 boxes
    BOOL show_soundings;
    double shallow, safety, deep; // depth-band contours, meters
} MarinerSettings;

static NSData *applyMariner(NSData *styleJson, MarinerSettings m) {
    NSMutableDictionary *style =
        [NSJSONSerialization JSONObjectWithData:styleJson
                                        options:NSJSONReadingMutableContainers
                                          error:nil];
    if (!style) return styleJson;
    if (m.mlt_source) {
        NSMutableDictionary *sources = style[@"sources"];
        for (NSString *sname in sources) {
            NSMutableDictionary *src = sources[sname];
            if ([src[@"type"] isEqualToString:@"vector"]) src[@"encoding"] = @"mlt";
        }
    }
    NSMutableArray *layers = style[@"layers"];
    int hidden = 0, requalified = 0, recontoured = 0;

    for (NSMutableDictionary *l in layers) {
        NSString *lid = l[@"id"];
        NSString *src = l[@"source-layer"];
        if (!src) continue; // background

        // Data quality: tile57's category filter drops features tagged mq=1
        // unless the setting is on (mariner.zig categoryFilter).
        if (!m.data_quality) {
            andFilter(l, jarr(@[ @"!=", jarr(@[ @"coalesce", jarr(@[ @"get", @"mq" ]), @0 ]), @1 ]));
            requalified++;
        }
        // Information callouts: the same builder drops symbol_name INFORM01.
        if (!m.show_inform_callouts && [src isEqualToString:@"point_symbols"]) {
            andFilter(l, jarr(@[ @"!=", jarr(@[ @"coalesce", jarr(@[ @"get", @"symbol_name" ]), @"" ]), @"INFORM01" ]));
        }
        // Soundings are their own switch in every ECDIS, tile57 included.
        if (!m.show_soundings && [src isEqualToString:@"soundings"]) {
            NSMutableDictionary *layout = l[@"layout"];
            if (!layout) { layout = [NSMutableDictionary dictionary]; l[@"layout"] = layout; }
            layout[@"visibility"] = @"none";
            hidden++;
        }
        // The depth bands, on the area fills that carry them.
        if ([lid hasPrefix:@"fill-areas"]) {
            NSMutableDictionary *paint = l[@"paint"];
            id fc = paint[@"fill-color"];
            if (fc) {
                fc = rewriteContours(fc, 30.0, m.deep);
                fc = rewriteContours(fc, 10.0, m.safety);
                fc = rewriteContours(fc, 2.0, m.shallow);
                paint[@"fill-color"] = fc;
                recontoured++;
            }
        }
    }
    NSLog(@"mariner: quality %s, info callouts %s, soundings %s, contours %.0f/%.0f/%.0f "
          @"(%d layers gated, %d hidden, %d recontoured)",
          m.data_quality ? "on" : "off", m.show_inform_callouts ? "on" : "off",
          m.show_soundings ? "on" : "off", m.shallow, m.safety, m.deep,
          requalified, hidden, recontoured);
    return [NSJSONSerialization dataWithJSONObject:style options:0 error:nil];
}

// Shared by both build configurations: the map handle the async callbacks
// answer into, and the sprite density they rasterized at. These lived inside
// the compose block below, which left the PLAIN build with no g_map at all.
static charttable *g_map;
static double g_asset_ratio = 1.0;

#ifdef USE_TILE57_COMPOSE
/// Build the style the way tile57 does: template + mariner + colortables,
/// with the SCAMIN manifest so the `_scamin` layers split into per-value
/// buckets that each carry a native minzoom. Without the manifest those
/// layers collapse into ONE ungated layer -- every feature renders at every
/// zoom, which is what "SCAMIN is not honored" looks like, and no amount of
/// work in the renderer can fix it because the style never asked.
///
/// This also retires the hand-rolled JSON surgery: depth shading, the
/// sounding and danger swaps, the category/callout/quality filters and the
/// per-scheme recolour are all mariner-driven here, from one struct.
static NSData *buildStyle(const tile57_mariner *m, const int32_t *scamin, size_t nscamin,
                          double scamin_lat, BOOL mlt) {
    tile57_error e = {0};
    uint8_t *ct = NULL; size_t ctn = 0;
    if (tile57_colortables_default(&ct, &ctn, &e) != TILE57_OK) {
        NSLog(@"colortables: %s", e.message);
        return nil;
    }
    uint8_t *tpl = NULL; size_t tn = 0;
    // encoding 1 = MLT, which is what the compositor serves.
    // The sprite and glyphs URLs are what ENABLE the symbol/pattern and text
    // layer groups in the template -- pass NULL and you get a fills-and-lines
    // style (69 layers instead of 179). charttable never fetches them: the
    // host hands it the atlases through the ABI. So the values only have to
    // exist.
    if (tile57_style_template(m->scheme, "local/{z}/{x}/{y}",
                              "local://sprite", "local://glyphs/{fontstack}/{range}.pbf",
                              0, 0, mlt ? 1 : 0, &tpl, &tn, &e) != TILE57_OK) {
        NSLog(@"style template: %s", e.message);
        tile57_free(ct);
        return nil;
    }
    uint8_t *out = NULL; size_t on = 0;
    tile57_status st = tile57_style_build((const char *)tpl, tn, m, (const char *)ct, ctn,
                                          NULL, 0, scamin, nscamin, scamin_lat,
                                          &out, &on, &e);
    tile57_free(tpl);
    tile57_free(ct);
    if (st != TILE57_OK) {
        NSLog(@"style build: %s", e.message);
        return nil;
    }
    NSData *d = [NSData dataWithBytes:out length:on];
    tile57_free(out);
    NSLog(@"style: built from template (%zu scamin buckets, lat %.2f)", nscamin, scamin_lat);
    return d;
}

/// The distinct SCAMIN denominators across the library, and a representative
/// latitude for the bucket cutoffs (they are latitude-dependent).
static size_t collectScamin(NSString *dir, int32_t **out, double *out_lat) {
    NSMutableIndexSet *vals = [NSMutableIndexSet indexSet];
    double lat_sum = 0; int lat_n = 0;
    for (NSString *rel in [NSFileManager.defaultManager enumeratorAtPath:dir]) {
        if (![rel.pathExtension isEqualToString:@"pmtiles"]) continue;
        NSString *full = [dir stringByAppendingPathComponent:rel];
        tile57_chart *c = NULL; tile57_error e = {0};
        if (tile57_chart_open(full.UTF8String, &c, &e) != TILE57_OK) continue;
        int32_t *sc = NULL; size_t n = 0;
        if (tile57_chart_scamin(c, &sc, &n, &e) == TILE57_OK && sc) {
            for (size_t i = 0; i < n; i++)
                if (sc[i] > 0) [vals addIndex:(NSUInteger)sc[i]];
            tile57_free(sc);
        }
        tile57_chart_close(c);
        (void)lat_sum; (void)lat_n;
    }
    size_t n = vals.count;
    int32_t *arr = calloc(n ? n : 1, sizeof(int32_t));
    __block size_t i = 0;
    [vals enumerateIndexesUsingBlock:^(NSUInteger v, BOOL *stop) { arr[i++] = (int32_t)v; }];
    *out = arr;
    return n;
}

static tile57_compose *g_compose;
static double g_compose_ms;   // benchmark attribution: time spent composing
static int g_compose_n;
static double g_symbol_ms;   // benchmark attribution: inline symbol rasterization
static int g_symbol_n;

/// Bake the sprite sheet for THIS display. The prebaked sheet on disk is
/// rasterized at ratio 1, so on a Retina panel every symbol is a 2x upscale
/// of a 1x bitmap -- correct size, soft edges. The engine rasterizes the
/// catalogue at any ratio, so ask it for the one we actually draw at.
static BOOL bakeSprite(charttable *m, double ratio) {
    tile57_assets a = {0};
    tile57_error e = {0};
    if (tile57_bake_sprite_mln(NULL, ratio, TILE57_SCHEME_DAY, &a, &e) != TILE57_OK) {
        NSLog(@"sprite bake failed: %s", e.message);
        return NO;
    }
    BOOL ok = charttable_set_sprite(m, (const char *)a.sprite_json, a.sprite_json_len,
                                    a.sprite_png, a.sprite_png_len) == CHARTTABLE_OK;
    NSLog(@"sprite: baked at ratio %.1f (%zu B json, %zu B png)%s",
          ratio, a.sprite_json_len, a.sprite_png_len, ok ? "" : " -- REJECTED");
    tile57_assets_free(&a);
    return ok;
}

/// The missing-image answer. A chart library carries more distinct sounding
/// runs ("SOUNDG11,SOUNDG53") than any prebaked sheet can enumerate, so the
/// style asks for them by name and the host renders exactly the ones the
/// display wants. Without this every multi-digit sounding is simply absent.
static void onMissingImage(const char *name, void *user) {
    (void)user;
    uint8_t *rgba = NULL; uint32_t w = 0, h = 0;
    tile57_error e = {0};
    double t_sym = CACurrentMediaTime() * 1000.0;
    g_symbol_n++;
    if (tile57_render_symbol_run(NULL, name, g_asset_ratio, TILE57_SCHEME_DAY,
                                 &rgba, &w, &h, &e) != TILE57_OK || !rgba)
        return;
    charttable_add_image(g_map, name, rgba, w, h, (float)g_asset_ratio);
    tile57_free(rgba);
    g_symbol_ms += CACurrentMediaTime() * 1000.0 - t_sym;
}

/// Answer charttable's tile request from tile57's compositor, which resolves
/// cell ownership through the baked partition -- the thing that makes a
/// library quilt instead of tile-fight.
///
/// Two things the header is explicit about and I got wrong first time:
/// `out_owned` does NOT mean "you own this buffer", it distinguishes two
/// kinds of EMPTY (nobody owns the ground vs an owner that produced
/// nothing); and every engine buffer is released with tile57_free, never
/// libc free -- the engine allocates them length-prefixed with its own
/// allocator, and free() on one aborts the process.
/// The compositor is NOT internally synchronized -- the header is explicit
/// that one handle must not be entered from two threads -- so composing gets
/// ONE serial queue rather than a concurrent one. That is enough: the point
/// is to keep the ~5 ms/tile off the frame thread, not to compose in
/// parallel. A second compositor would mean reopening all 7224 archives.
static dispatch_queue_t composeQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("charttable.compose", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static void composeNow(uint64_t req_id, uint32_t z, uint32_t x, uint32_t y) {
    uint8_t *bytes = NULL; size_t len = 0; bool owned = false;
    tile57_error e = {0};
    double t0 = CACurrentMediaTime() * 1000.0;
    tile57_status st = tile57_compose_tile(g_compose, (uint8_t)z, x, y, &bytes, &len, &owned, &e);
    g_compose_ms += CACurrentMediaTime() * 1000.0 - t0;
    g_compose_n++;
    if (st == TILE57_OK && bytes && len) {
        charttable_resource_respond(g_map, req_id, bytes, len, CHARTTABLE_RESOURCE_OK);
        tile57_free(bytes);
        return;
    }
    if (bytes) tile57_free(bytes);
    // The bakes are complete, so "an owner produced nothing" is a real empty
    // here, not a transient worth parking on.
    charttable_resource_respond(g_map, req_id, NULL, 0,
                                st == TILE57_OK ? CHARTTABLE_RESOURCE_EMPTY
                                                : CHARTTABLE_RESOURCE_FAILED);
}

/// charttable raises asks on the OWNER thread, inside charttable_tick. Doing
/// the compose here would put a disk read, a decompress and a multi-chart
/// merge in the middle of a frame -- measured at 197 ms of a 325 ms pinch,
/// 61% of all frame time. The ABI is built for exactly this: the request
/// PARKS until answered, and the answer may come from any thread at any
/// time, so hand it to the queue and return immediately.
static void onComposeTile(uint64_t req_id, const char *source, uint32_t z, uint32_t x, uint32_t y,
                          void *user) {
    (void)source; (void)user;
    dispatch_async(composeQueue(), ^{ composeNow(req_id, z, x, y); });
}
#endif


// ---- remote styles ---------------------------------------------------------
//
// charttable fetches nothing, by design: the host owns where bytes come from.
// So a style served over HTTP is entirely the app's job -- pull the style,
// resolve the URLs inside it against the style's own address, pull the sprite
// and glyphs, and answer tile requests from the source's URL template.

static BOOL isURL(NSString *s) {
    return [s hasPrefix:@"http://"] || [s hasPrefix:@"https://"];
}

/// Blocking GET, for the handful of things fetched before the first frame:
/// the style, its sprite, its glyph ranges.
static NSData *fetchURL(NSString *url) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *out = nil;
    NSURLSessionDataTask *t = [NSURLSession.sharedSession
        dataTaskWithURL:[NSURL URLWithString:url]
      completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          NSInteger code = [r isKindOfClass:NSHTTPURLResponse.class]
                               ? ((NSHTTPURLResponse *)r).statusCode : 0;
          if (e) NSLog(@"GET %@: %@", url, e.localizedDescription);
          else if (code >= 400) NSLog(@"GET %@: HTTP %ld", url, (long)code);
          else out = d;
          dispatch_semaphore_signal(done);
      }];
    [t resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    return out;
}

/// Style URLs may be relative ("/sprite", "sprite.png"), and MapLibre also
/// allows the mapbox:// forms, which are not resolvable without a token --
/// those are reported rather than guessed at.
static NSString *resolveURL(NSString *ref, NSString *base) {
    if (!ref) return nil;
    // The array sprite form ([{id,url},…]) is tier 2; take the LAST sheet's
    // url so a style that layers a nautical sheet over a base sheet at least
    // resolves the one it draws seamarks from.
    if ([ref isKindOfClass:NSArray.class]) {
        NSDictionary *entry = ((NSArray *)ref).lastObject;
        ref = [entry isKindOfClass:NSDictionary.class] ? entry[@"url"] : nil;
        if (!ref) return nil;
    }
    if (![ref isKindOfClass:NSString.class]) return nil;
    if (isURL(ref)) return ref;
    if ([ref hasPrefix:@"mapbox://"]) { NSLog(@"cannot resolve %@ (no token)", ref); return nil; }
    if (!base) return ref;
    return [[NSURL URLWithString:ref relativeToURL:[NSURL URLWithString:base]] absoluteString];
}

/// source name -> tile URL template, filled from the style.
static NSMutableDictionary<NSString *, NSString *> *g_tileURLs;

static void onHTTPTile(uint64_t req_id, const char *sourceC, uint32_t z, uint32_t x, uint32_t y,
                       void *user) {
    (void)user;
    // The name belongs to the caller; the block below outlives this frame.
    NSString *source = @(sourceC);
    NSString *tmpl = g_tileURLs[source];
    if (!tmpl) {
        charttable_resource_respond(g_map, req_id, NULL, 0, CHARTTABLE_RESOURCE_FAILED);
        return;
    }
    NSString *url = [[[tmpl stringByReplacingOccurrencesOfString:@"{z}"
                                                      withString:@(z).stringValue]
        stringByReplacingOccurrencesOfString:@"{x}" withString:@(x).stringValue]
        stringByReplacingOccurrencesOfString:@"{y}" withString:@(y).stringValue];
    // Asynchronous on purpose: the request parks, and the callback runs on
    // the OWNER thread -- blocking here would put a network round trip in the
    // middle of a frame.
    [[NSURLSession.sharedSession
        dataTaskWithURL:[NSURL URLWithString:url]
      completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          NSInteger code = [r isKindOfClass:NSHTTPURLResponse.class]
                               ? ((NSHTTPURLResponse *)r).statusCode : 0;
          int st = CHARTTABLE_RESOURCE_OK;
          // 404 is a real "nothing there" and is worth remembering; anything
          // else that went wrong is a failure, not an empty tile.
          if (e || code >= 400 || !d.length)
              st = (code == 404 || (!e && !d.length)) ? CHARTTABLE_RESOURCE_EMPTY
                                                      : CHARTTABLE_RESOURCE_FAILED;
          if (getenv("CHARTTABLE_TRACE_TILES"))
              NSLog(@"tile %@ %u/%u/%u -> %ld bytes, status %d", source, z, x, y,
                    (long)d.length, st);
          charttable_resource_respond(g_map, req_id, st == CHARTTABLE_RESOURCE_OK ? d.bytes : NULL,
                                      st == CHARTTABLE_RESOURCE_OK ? d.length : 0, st);
      }] resume];
}

/// Sprite and glyphs named by the style, through the ABI. charttable never
/// goes and gets these itself, so a style that asks for them and a host that
/// ignores the ask is a chart with no icons and no labels.
static void loadRemoteAssets(charttable *map, NSDictionary *sj, NSString *base, double ratio) {
    NSString *sprite = resolveURL(sj[@"sprite"], base);
    if (sprite) {
        // @2x first on a Retina panel; the 1x sheet is the fallback.
        NSString *suffix = ratio >= 2 ? @"@2x" : @"";
        NSData *idx = fetchURL([NSString stringWithFormat:@"%@%@.json", sprite, suffix]);
        NSData *png = fetchURL([NSString stringWithFormat:@"%@%@.png", sprite, suffix]);
        if (!idx || !png) {
            idx = fetchURL([sprite stringByAppendingString:@".json"]);
            png = fetchURL([sprite stringByAppendingString:@".png"]);
        }
        if (idx && png &&
            charttable_set_sprite(map, idx.bytes, idx.length, png.bytes, png.length) == CHARTTABLE_OK)
            NSLog(@"sprite: %@ (%lu B json, %lu B png)", sprite,
                  (unsigned long)idx.length, (unsigned long)png.length);
        else
            NSLog(@"sprite %@ unavailable -- icons will be missing", sprite);
    }

    NSString *glyphs = resolveURL(sj[@"glyphs"], base);
    if (!glyphs) return;
    // Which fontstacks the style actually asks for, so this fetches what is
    // used rather than a guess.
    NSMutableSet<NSString *> *stacks = [NSMutableSet set];
    for (NSDictionary *L in sj[@"layers"]) {
        id f = L[@"layout"][@"text-font"];
        if ([f isKindOfClass:NSArray.class] && [f count] && [f[0] isKindOfClass:NSString.class])
            [stacks addObject:[f componentsJoinedByString:@","]];
    }
    if (!stacks.count) return;
    int loaded = 0;
    for (NSString *stack in stacks) {
        NSString *enc = [stack stringByAddingPercentEncodingWithAllowedCharacters:
                                   NSCharacterSet.URLPathAllowedCharacterSet];
        // Latin plus Latin-1 covers the labels in a western style; more ranges
        // are a fetch each and this is a test harness, not a map app.
        for (NSString *range in @[ @"0-255", @"256-511" ]) {
            NSString *u = [[glyphs stringByReplacingOccurrencesOfString:@"{fontstack}" withString:enc]
                stringByReplacingOccurrencesOfString:@"{range}" withString:range];
            NSData *pbf = fetchURL(u);
            if (pbf && charttable_add_glyphs(map, pbf.bytes, pbf.length) == CHARTTABLE_OK) loaded++;
        }
    }
    NSLog(@"glyphs: %d ranges from %lu fontstack(s)", loaded, (unsigned long)stacks.count);
}

@interface ChartView : NSView
@end

@implementation ChartView {
    charttable *_map;
    NSTimer *_timer;
    NSPoint _last;      // previous drag point, view coords
    BOOL _dragging;
    // Drag velocity, for the flick. Smoothed so one jittery last sample
    // cannot throw the fling off in a direction the finger never went.
    double _velX, _velY;
    double _lastDragMs;
    double _lastTickMs; // the host owns the clock; charttable never reads one
}

- (instancetype)initWithMap:(charttable *)map {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 1024, 768)])) {
        _map = map;
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    }
    return self;
}

// charttable works in y-down screen pixels, so let the view agree and every
// coordinate below is already in the right frame.
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (CALayer *)makeBackingLayer {
    CAMetalLayer *l = [CAMetalLayer layer];
    l.device = MTLCreateSystemDefaultDevice();
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    l.presentsWithTransaction = NO;
    return l;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) return;
    [self syncScale];

    NSSize pt = self.bounds.size;
    CGFloat scale = self.window.backingScaleFactor;
    int rc = charttable_attach_surface(_map, CHARTTABLE_NATIVE_METAL_LAYER,
                                       (__bridge void *)self.layer,
                                       (uint32_t)(pt.width * scale),
                                       (uint32_t)(pt.height * scale));
    if (rc != CHARTTABLE_OK) {
        NSLog(@"attach_surface failed: %d", rc);
        return;
    }
    charttable_set_pixel_density(_map, (float)scale);
    charttable_resize(_map, (uint32_t)pt.width, (uint32_t)pt.height);

    // 60 Hz is plenty; charttable only draws when something changed.
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                             repeats:YES
                                               block:^(NSTimer *t) { [self step]; }];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)syncScale {
    CGFloat scale = self.window ? self.window.backingScaleFactor : 1.0;
    self.layer.contentsScale = scale;
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self syncScale];
    charttable_set_pixel_density(_map, (float)self.window.backingScaleFactor);
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    self.layer.frame = self.bounds;
    charttable_resize(_map, (uint32_t)size.width, (uint32_t)size.height);
}

- (void)step {
    double now = CACurrentMediaTime() * 1000.0;
    double dt = _lastTickMs > 0 ? now - _lastTickMs : 0;
    _lastTickMs = now;
    if (charttable_tick(_map, dt) != CHARTTABLE_OK) NSLog(@"tick failed");
    if (getenv("CHARTTABLE_TRACE_VIEW")) {
        static int n = 0;
        if (n++ % 60 == 0) {
            charttable_view cur = {0};
            charttable_get_view(_map, &cur);
            NSSize sz = self.bounds.size;
            NSLog(@"view: lon %.4f lat %.4f zoom %.2f | viewport %.0fx%.0f pending %u",
                  cur.lon, cur.lat, cur.zoom, sz.width, sz.height,
                  charttable_pending_tiles(_map));
        }
    }
    // Honest damage: a still camera over a settled map draws nothing. A pan
    // or zoom counts, so input needs no special case here.
    if (charttable_needs_redraw(_map)) charttable_render(_map);
}

// ---- input ----------------------------------------------------------------

- (NSPoint)pointOf:(NSEvent *)e {
    return [self convertPoint:e.locationInWindow fromView:nil];
}

- (void)mouseDown:(NSEvent *)e {
    _last = [self pointOf:e];
    _dragging = YES;
    _velX = _velY = 0;
    _lastDragMs = CACurrentMediaTime() * 1000.0;
    charttable_fling(_map, 0, 0); // a touch stops a fling in progress
}

- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = [self pointOf:e];
    double dx = p.x - _last.x, dy = p.y - _last.y;
    charttable_pan(_map, (float)dx, (float)dy);

    double now = CACurrentMediaTime() * 1000.0;
    double dt = now - _lastDragMs;
    if (dt > 0.5) { // ignore duplicate samples in the same millisecond
        // Exponential smoothing: recent motion dominates, but a single
        // stutter at lift-off cannot define the throw.
        const double a = 0.6;
        _velX = a * (dx * 1000.0 / dt) + (1 - a) * _velX;
        _velY = a * (dy * 1000.0 / dt) + (1 - a) * _velY;
        _lastDragMs = now;
    }
    _last = p;
    charttable_render(_map); // draw on the event so the drag feels attached
}

- (void)mouseUp:(NSEvent *)e {
    _dragging = NO;
    // Let go while still moving and the chart carries on. A stale sample
    // (finger held still before lifting) should NOT fling.
    double idle = CACurrentMediaTime() * 1000.0 - _lastDragMs;
    double speed = sqrt(_velX * _velX + _velY * _velY);
    if (idle < 80 && speed > 60) charttable_fling(_map, _velX, _velY);
}

// Scroll ALWAYS zooms, anchored at the pointer -- lookout-marine's rule
// (ChartView.swift). Panning is the drag gesture; a two-finger scroll that
// panned instead would leave a trackpad with no way to zoom but the pinch.
// Trackpad deltas are large, a wheel notch is about +-1, hence the two
// factors, which are lookout's.
- (void)scrollWheel:(NSEvent *)e {
    NSPoint p = [self pointOf:e];
    double factor = e.hasPreciseScrollingDeltas ? 0.01 : 0.25;
    double dz = e.scrollingDeltaY * factor;
    // Eased, so a wheel notch glides instead of snapping.
    if (dz != 0) charttable_zoom_toward(_map, dz, (float)p.x, (float)p.y);
}

- (void)magnifyWithEvent:(NSEvent *)e {
    NSPoint p = [self pointOf:e];
    // A live pinch tracks the fingers exactly -- easing a continuous gesture
    // would lag it -- so this one stays instant.
    charttable_zoom_at(_map, e.magnification * 3.0, (float)p.x, (float)p.y);
}

- (void)keyDown:(NSEvent *)e {
    NSPoint mid = NSMakePoint(NSWidth(self.bounds) / 2, NSHeight(self.bounds) / 2);
    const float step = 60;
    unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
    switch (c) {
        case '+': case '=': charttable_zoom_toward(_map, 0.5, (float)mid.x, (float)mid.y); break;
        case '-': case '_': charttable_zoom_toward(_map, -0.5, (float)mid.x, (float)mid.y); break;
        case NSLeftArrowFunctionKey:  charttable_pan(_map, step, 0); break;
        case NSRightArrowFunctionKey: charttable_pan(_map, -step, 0); break;
        case NSUpArrowFunctionKey:    charttable_pan(_map, 0, step); break;
        case NSDownArrowFunctionKey:  charttable_pan(_map, 0, -step); break;
        default: [super keyDown:e]; return;
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        NSString *arg1 = argc > 1 ? @(argv[1]) : nil;
        // A URL, or a .json file, IS the style: it names its own tile
        // sources, so there may be no local chart to open at all.
        const BOOL remoteStyle = arg1 && (isURL(arg1) ||
                                          [arg1.pathExtension isEqualToString:@"json"]);
        NSString *chart = remoteStyle ? nil
                        : arg1 ?: [home stringByAppendingPathComponent:
                                            @"Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles"];
        // argv[2] or CHARTTABLE_STYLE: any MapLibre style JSON, used
        // VERBATIM. No mariner surgery, no tile57 style build, no S-52
        // assumptions -- the point is to test charttable against an ordinary
        // style, so nothing here may quietly rewrite it. Sources are bound
        // under the names the style itself declares.
        NSString *stylePath = remoteStyle ? arg1 : (argc > 2 ? @(argv[2]) : nil);
        if (!stylePath && getenv("CHARTTABLE_STYLE")) stylePath = @(getenv("CHARTTABLE_STYLE"));
        const BOOL customStyle = stylePath != nil;

        charttable_options opts = { .workers = 4 };
        charttable *map = charttable_open(&opts);
        if (!map) { NSLog(@"charttable_open failed"); return 1; }

        const char *spriteDir = getenv("CHARTTABLE_SPRITE_DIR");
        const char *glyphDir = getenv("CHARTTABLE_GLYPHS_DIR");
        BOOL haveSprite = NO;


#ifdef USE_TILE57_COMPOSE
        // Bake for the display we are on, and answer missing images live.
        g_map = map;
        g_asset_ratio = NSScreen.mainScreen.backingScaleFactor;
        haveSprite = bakeSprite(map, g_asset_ratio);
        charttable_set_missing_image_callback(map, onMissingImage, NULL);
        if (!haveSprite)
#endif
        if (spriteDir) haveSprite = loadSprite(map, @(spriteDir));
        // Text needs a glyph atlas, and charttable fetches nothing itself:
        // with none supplied, every label silently does not draw. Fall back
        // to the checked-in fontnik ranges so text is on by default rather
        // than depending on the launcher remembering an env var.
        if (!glyphDir) {
            for (NSString *guess in @[ @"test/assets", @"../../test/assets" ]) {
                NSString *probe = [guess stringByAppendingPathComponent:@"Noto Sans Regular/0-255.pbf"];
                if ([NSFileManager.defaultManager fileExistsAtPath:probe]) {
                    glyphDir = guess.UTF8String;
                    break;
                }
            }
        }
        if (glyphDir) loadGlyphs(map, @(glyphDir));
#ifdef USE_TILE57_COMPOSE
        // No font files needed: the engine that draws the symbols bakes the
        // label font too, as an SDF sheet charttable takes directly.
        if (!glyphDir) {
            tile57_assets ga = {0};
            tile57_error ge = {0};
            if (tile57_bake_glyph_sdf(&ga, &ge) == TILE57_OK) {
                CGImageSourceRef src = CGImageSourceCreateWithData(
                    (__bridge CFDataRef)[NSData dataWithBytes:ga.sprite_png length:ga.sprite_png_len],
                    NULL);
                CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
                if (img) {
                    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
                    NSMutableData *rgba = [NSMutableData dataWithLength:w * h * 4];
                    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                    CGContextRef ctx = CGBitmapContextCreate(rgba.mutableBytes, w, h, 8, w * 4, cs,
                                                             kCGImageAlphaPremultipliedLast);
                    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
                    int rc = charttable_set_glyph_sheet(map, (const char *)ga.sprite_json,
                                                        ga.sprite_json_len, rgba.bytes,
                                                        (uint32_t)w, (uint32_t)h);
                    NSLog(@"glyphs: tile57 SDF sheet %zux%zu -> rc=%d", w, h, rc);
                    CGContextRelease(ctx);
                    CGColorSpaceRelease(cs);
                    CGImageRelease(img);
                    glyphDir = "";  // handled
                }
                if (src) CFRelease(src);
                tile57_assets_free(&ga);
            } else {
                NSLog(@"glyph bake failed: %s", ge.message);
            }
        }
#endif
        if (!glyphDir) NSLog(@"no glyphs: text will not draw");

        if (!stylePath) {
            NSString *assets = @"test/assets";
            stylePath = [assets stringByAppendingPathComponent:
                                    haveSprite ? @"chart-day-style-symbols.json"
                                               : @"chart-day-style.json"];
        }

        // The starting view, needed before the style: SCAMIN cutoffs are
        // latitude-dependent, so the bucket minzooms want our latitude.
        charttable_view v = { .lon = -76.4767, .lat = 38.9763, .zoom = 14 };
        const char *ev;
        if ((ev = getenv("CHARTTABLE_LON"))) v.lon = atof(ev);
        if ((ev = getenv("CHARTTABLE_LAT"))) v.lat = atof(ev);
        if ((ev = getenv("CHARTTABLE_ZOOM"))) v.zoom = atof(ev);

        BOOL composing = NO;
#ifdef USE_TILE57_COMPOSE
        {
            BOOL d = NO;
            [NSFileManager.defaultManager fileExistsAtPath:chart isDirectory:&d];
            // A supplied style is not the chart schema, so the compositor --
            // which serves S-52 layers as MLT -- has nothing it can say to
            // it. Read the archives directly instead.
            composing = d && !customStyle;
        }
#endif

        // 1.0 draws the sprite at its authored size, which is what the sprite
        // asks for: tile57 bakes SYMBOL cells at pixelRatio 1 ("a consumer
        // draws them at the same LOGICAL size"), so a 12 px cell is meant to
        // be 12 px. Do NOT calibrate this against `tile57 png` -- that tool
        // renders tile57's own S-52 portrayal at its own physical scale and
        // takes no --style, so it is an oracle for fill colors and not for
        // symbol geometry. CHARTTABLE_SIZE_SCALE overrides it.
        float size_scale = 1.0f;
        const char *ss_env = getenv("CHARTTABLE_SIZE_SCALE");
        if (ss_env) size_scale = atof(ss_env);
        charttable_set_size_scale(map, size_scale);

        // S-52 display category: Base, Standard, and Other. Other is ON,
        // which is what a mariner working a chart wants and what
        // lookout-marine shows -- with it off, whole classes of feature
        // (the spot soundings among them) are simply absent.
        // CHARTTABLE_DISPLAY_OTHER=0 turns it back off.
        const char *other_env = getenv("CHARTTABLE_DISPLAY_OTHER");
        const BOOL displayOther = !(other_env && other_env[0] == '0');

        NSData *style = nil;
        BOOL builtStyle = NO;
        if (customStyle) NSLog(@"style: %@ (used verbatim)", stylePath);
#ifdef USE_TILE57_COMPOSE
        if (composing) {
            // The mariner settings this session runs with, straight into the
            // engine's own style builder -- no JSON surgery.
            tile57_mariner tm = {0};
            tm.scheme = TILE57_SCHEME_DAY;
            tm.shallow_contour = 7; tm.safety_contour = 7;
            tm.deep_contour = 12;   tm.safety_depth = 7;
            tm.four_shade_water = true;
            tm.depth_unit = 0; // metres
            tm.display_base = true; tm.display_standard = true;
            tm.display_other = displayOther;
            tm.data_quality = false;         // seabed-quality overlay off
            tm.show_inform_callouts = false; // the [i] boxes off
            tm.soundings = 1;                // spot soundings on
            tm.text_names = true; tm.show_light_descriptions = true; tm.text_other = true;
            tm.boundary_style = 0; tm.simplified_points = false;
            tm.show_overscale = true;
            tm.size_scale = size_scale;
            tm.text_size_scale = 1.0; tm.sounding_size_scale = 1.0;
            tm.device_scale = 1.0;

            int32_t *scamin = NULL;
            double lat = v.lat;
            size_t nscamin = collectScamin(chart, &scamin, &lat);
            NSLog(@"scamin: %zu distinct denominators across the library", nscamin);
            style = buildStyle(&tm, scamin, nscamin, lat, YES);
            builtStyle = style != nil;
            free(scamin);
        }
#endif
        NSString *styleBase = nil;
        if (!style && isURL(stylePath)) {
            style = fetchURL(stylePath);
            styleBase = stylePath;
        }
        if (!style) style = readFile(stylePath);
        if (!style) { NSLog(@"cannot read style %@", stylePath); return 1; }

        if (spriteDir && !haveSprite) NSLog(@"sprite dir set but no sprite-mln.{json,png} in it");

        // The mariner settings this session runs with. Depth contours in
        // meters: shallow / safety / deep (safety-depth splits bold vs faint
        // soundings and is a tile57 bake concern, not a style one).
        MarinerSettings mariner = {
            .mlt_source = composing,
            .data_quality = NO,
            .show_inform_callouts = NO,
            .show_soundings = YES,
            .shallow = 7,
            .safety = 7,
            .deep = 12,
        };
        if (!builtStyle && !customStyle) style = applyMariner(style, mariner);
        // Whichever path built it, the source must declare what the tiles
        // ARE. The compositor serves raw MLT; a vector source that omits
        // `encoding` means MVT, and every tile fails to decode -- a clean
        // parse, no diagnostics, and a blank window.
        if (composing) style = stampEncoding(style, @"mlt");
        // Only needed when Other is off: it lifts the soundings out of a
        // category that is not being drawn.
        if (builtStyle && !displayOther) style = soundingsIndependentOfCategory(style);

        const char *dump = getenv("CHARTTABLE_DUMP_STYLE");
        if (dump) [style writeToFile:@(dump) atomically:YES];
        // CHARTTABLE_ONLY=substr / CHARTTABLE_HIDE=substr -- peel the render
        // apart by layer id to find which layer draws a given artifact.
        NSString *only = getenv("CHARTTABLE_ONLY") ? @(getenv("CHARTTABLE_ONLY")) : nil;
        NSString *hide = getenv("CHARTTABLE_HIDE") ? @(getenv("CHARTTABLE_HIDE")) : nil;
        if (charttable_set_style_json(map, style.bytes, style.length) != CHARTTABLE_OK) {
            NSLog(@"style rejected"); return 1;
        }
        // CHARTTABLE_FILTER='layer|<json filter>' -- narrow one layer to a
        // subset of its features, to ask which of them draws a given pixel.
        const char *filt = getenv("CHARTTABLE_FILTER");
        if (filt) {
            NSArray *parts = [@(filt) componentsSeparatedByString:@"|"];
            if (parts.count == 2) {
                int rc = charttable_set_filter(map, [parts[0] UTF8String],
                                               [parts[1] UTF8String],
                                               (uint32_t)[parts[1] length]);
                NSLog(@"filter on %@: %@ -> rc=%d", parts[0], parts[1], rc);
            }
        }
        if (only || hide) {
            NSDictionary *sj = [NSJSONSerialization JSONObjectWithData:style options:0 error:nil];
            int n_off = 0, n_on = 0;
            for (NSDictionary *L in sj[@"layers"]) {
                NSString *lid = L[@"id"];
                BOOL want = only ? ([lid rangeOfString:only].location != NSNotFound)
                                 : ([lid rangeOfString:hide].location == NSNotFound);
                charttable_set_layer_visibility(map, lid.UTF8String, want ? 1 : 0);
                if (want) n_on++; else n_off++;
            }
            NSLog(@"layers: %d shown, %d hidden (%@ %@)", n_on, n_off,
                  only ? @"only" : @"hide", only ?: hide);
        }
        {   // The style parser degrades rather than rejects, so ALWAYS look:
            // a silently-dropped layer is the difference between a chart and
            // a blank window.
            size_t dlen = 0;
            const char *diag = charttable_style_diagnostics(map, &dlen);
            if (diag && dlen) {
                NSArray *ls = [@(diag) componentsSeparatedByString:@"\n"];
                NSLog(@"style diagnostics: %lu lines; first few:", (unsigned long)ls.count - 1);
                for (NSUInteger i = 0; i < MIN((NSUInteger)6, ls.count); i++)
                    if ([ls[i] length]) NSLog(@"   %@", ls[i]);
            }
        }
        // Which source names to bind the archives under. A chart style calls
        // it "chart"; an arbitrary MapLibre style calls it whatever it likes,
        // and a source charttable never binds is simply a layer that draws
        // nothing -- silently. So take the names from the style.
        NSMutableArray<NSString *> *srcNames = [NSMutableArray array];
        if (customStyle) {
            NSDictionary *sj = [NSJSONSerialization JSONObjectWithData:style options:0 error:nil];
            g_tileURLs = [NSMutableDictionary dictionary];
            NSMutableArray<NSString *> *localNames = [NSMutableArray array];
            for (NSString *name in sj[@"sources"]) {
                NSDictionary *src = sj[@"sources"][name];
                NSString *type = src[@"type"];
                // raster-dem is fetched and decoded exactly like a raster;
                // only the layers reading it treat the pixels as elevation.
                const BOOL isRaster = [type isEqualToString:@"raster"] ||
                                      [type isEqualToString:@"raster-dem"];
                if (![type isEqualToString:@"vector"] && !isRaster) {
                    NSLog(@"source '%@' is type '%@' -- skipped", name, type);
                    continue;
                }
                // Tiles may be listed inline, or behind a TileJSON document,
                // which also carries the zoom range the source really has.
                NSDictionary *tj = src;
                NSString *tmpl = [src[@"tiles"] isKindOfClass:NSArray.class] && [src[@"tiles"] count]
                                     ? resolveURL(src[@"tiles"][0], styleBase) : nil;
                if (!tmpl && src[@"url"]) {
                    NSString *tjurl = resolveURL(src[@"url"], styleBase);
                    NSData *d = tjurl ? fetchURL(tjurl) : nil;
                    NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0
                                                                               error:nil] : nil;
                    if ([json[@"tiles"] isKindOfClass:NSArray.class] && [json[@"tiles"] count]) {
                        tmpl = resolveURL(json[@"tiles"][0], tjurl);
                        tj = json;
                    }
                }
                if (tmpl) {
                    g_tileURLs[name] = tmpl;
                    charttable_provided_opts po = {
                        .kind = isRaster ? 1u : 0u,
                        .encoding = 0,
                        .minzoom = tj[@"minzoom"] ? [tj[@"minzoom"] unsignedIntValue] : 0,
                        .maxzoom = tj[@"maxzoom"] ? [tj[@"maxzoom"] unsignedIntValue] : 14,
                    };
                    if (charttable_add_source_provided_opts(map, name.UTF8String, &po) != CHARTTABLE_OK) {
                        NSLog(@"cannot route source '%@'", name); return 1;
                    }
                    NSLog(@"source '%@' (%@ z%u-%u) -> %@", name, type, po.minzoom, po.maxzoom, tmpl);
                } else {
                    [localNames addObject:name];   // served from the local archive
                }
            }
            if (g_tileURLs.count) {
                g_map = map;
                charttable_set_resource_provider(map, onHTTPTile, NULL);
                loadRemoteAssets(map, sj, styleBase, NSScreen.mainScreen.backingScaleFactor);
            }
            [srcNames addObjectsFromArray:localNames];
            if (srcNames.count == 0 && g_tileURLs.count == 0) {
                NSLog(@"style declares no vector source"); return 1;
            }
            if (srcNames.count) {
                if (!chart) { NSLog(@"source(s) %@ need a local chart argument",
                                    [srcNames componentsJoinedByString:@", "]); return 1; }
                NSLog(@"binding archives to source(s): %@", [srcNames componentsJoinedByString:@", "]);
            }
        } else {
            [srcNames addObject:@"chart"];
        }
        if (srcNames.count == 0) goto sources_done;

#ifdef USE_TILE57_COMPOSE
        // QUILTING. charttable's own multi-archive source picks a cell per
        // tile by bounds and compilation scale, which is a heuristic and
        // shows it: hard seams where one cell's data stops and the next
        // begins. Real quilting needs the ownership partition tile57 bakes
        // (partition.tpart), and tile57 already serves composed tiles
        // through it -- so let it, and feed charttable through the resource
        // provider. That is exactly what the provider is for: the host owns
        // where bytes come from.
        {
            BOOL isDirC = NO;
            [NSFileManager.defaultManager fileExistsAtPath:chart isDirectory:&isDirC];
            if (isDirC) {
                // One call: opens every archive under the tree AND loads the
                // partition sidecar the bake wrote, which is what resolves
                // ownership between overlapping cells.
                tile57_error e = {0};
                uint32_t nCharts = 0;
                if (tile57_compose_tree(chart.UTF8String, &g_compose, &nCharts, &e) == TILE57_OK) {
                    NSLog(@"quilt: tile57 compositor over %u charts", nCharts);
                    charttable_set_resource_provider(map, onComposeTile, NULL);
                    g_map = map;
                    if (charttable_add_source_provided(map, "chart") != CHARTTABLE_OK) {
                        NSLog(@"provided source failed"); return 1;
                    }
                    goto sources_done;
                }
                NSLog(@"compositor unavailable (%s); falling back to the built-in library", e.message);
            }
        }
#endif
        // A file, or a whole DIRECTORY of archives -- point it at an
        // ENC_ROOT and it opens the library. Repeat calls with one source
        // name build a library inside charttable: finest cell first, culled
        // by each archive's own header bounds, mapped lazily so an untouched
        // cell costs address space and nothing else.
        BOOL isDir = NO;
        [NSFileManager.defaultManager fileExistsAtPath:chart isDirectory:&isDir];
        int opened = 0, failed = 0;
        if (isDir) {
            NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtPath:chart];
            for (NSString *rel in walk) {
                if (![rel.pathExtension isEqualToString:@"pmtiles"]) continue;
                NSString *full = [chart stringByAppendingPathComponent:rel];
                BOOL ok = YES;
                for (NSString *nm in srcNames)
                    ok = ok && charttable_add_source_pmtiles(map, nm.UTF8String,
                                                             full.UTF8String) == CHARTTABLE_OK;
                if (ok) opened++; else failed++;
            }
            NSLog(@"library: %d archives opened from %@ (%d failed)", opened, chart, failed);
            if (opened == 0) { NSLog(@"no .pmtiles under %@", chart); return 1; }
        } else {
            for (NSString *nm in srcNames) {
                if (charttable_add_source_pmtiles(map, nm.UTF8String,
                                                  chart.UTF8String) != CHARTTABLE_OK) {
                    NSLog(@"cannot open chart %@ as source '%@'", chart, nm); return 1;
                }
            }
        }
    sources_done:;


        // How far out the camera may go.
        //
        // A chart library has a floor: below it the ENC data is a smear, the
        // wanted set is every tile on earth, and the compositor is asked to
        // merge thousands of cells per tile. There is no way to derive it
        // from the tiles themselves -- the partition covers the world at
        // every zoom -- so it comes from what the data IS: a bake of
        // coastal-scale charts stops being legible around z4. A style-driven
        // map keeps whatever the style implies.
        //
        // CHARTTABLE_MIN_ZOOM overrides it.
        {
            double floor_z = composing ? 4.0 : 0.0;
            const char *mz = getenv("CHARTTABLE_MIN_ZOOM");
            if (mz) floor_z = atof(mz);
            charttable_set_zoom_range(map, floor_z, 24.0);
            if (floor_z > 0) NSLog(@"zoom floor: z%.1f", floor_z);
        }

        // Annapolis harbor, the view the test suite renders.
        charttable_set_view(map, &v);

        // --snapshot FILE: render offscreen at the window size, density 1,
        // and exit. Same pixels a reference renderer can be diffed against,
        // which a screenshot of a Retina window is not.
        // CHARTTABLE_BENCHZOOM=1: script a pinch offscreen and report the
        // frame-time distribution. The Zig benchmarks time layout alone; this
        // is the whole frame -- decode, compose, symbols, upload, draw -- so
        // it is the number a hitch is actually felt in.
        if (getenv("CHARTTABLE_BENCHZOOM")) {
            // Retina-sized by default: the user's window is 2x, which means
            // four times the tiles per view, and tile SUPPLY is what a zoom
            // waits on.
            const uint32_t W = 1440, H = 900;
            if (charttable_attach_surface(map, CHARTTABLE_NATIVE_NONE, NULL, W, H) != CHARTTABLE_OK) {
                NSLog(@"offscreen surface failed"); return 1;
            }
            charttable_set_pixel_density(map, 2.0f);
            charttable_resize(map, W, H);
            for (int i = 0; i < 4000 && !charttable_idle(map); i++) {
                charttable_tick(map, 16);
                usleep(1000);
            }
            enum { FRAMES = 240 };
            int settled_at = -1;
            // CHARTTABLE_BENCHZOOM=out zooms OUT, which needs a whole new
            // tile set AND grows past the built coverage -- the direction
            // where a held scene leaves blank edges.
            double g_bench_dz = strcmp(getenv("CHARTTABLE_BENCHZOOM"), "out") == 0 ? -0.05 : 0.05;
            NSLog(@"benchzoom: %s", g_bench_dz < 0 ? "zooming OUT" : "zooming IN");
            double ms[FRAMES];
            double tick_ms = 0, render_ms = 0, worst = 0, worst_tick = 0, worst_render = 0;
            int n = 0;
            for (int i = 0; i < FRAMES; i++) {
                // 80 pinch events over 4 zoom levels, then fingers up.
                if (i < 80) charttable_zoom_at(map, g_bench_dz, W / 2, H / 2);
                double t0 = CACurrentMediaTime() * 1000.0;
                charttable_tick(map, 1000.0 / 60.0);
                double t1 = CACurrentMediaTime() * 1000.0;
                if (charttable_needs_redraw(map)) charttable_render(map);
                double t2 = CACurrentMediaTime() * 1000.0;
                tick_ms += t1 - t0;
                render_ms += t2 - t1;
                if (t2 - t0 > worst) { worst = t2 - t0; worst_tick = t1 - t0; worst_render = t2 - t1; }
                // How much of the screen actually has chart on it. A zoom
                // that blanks shows up here as coverage collapsing, which a
                // frame-time number cannot see at all.
                if (i == 3 || i == 8 || i == 15 || i == 30 || i == 50 || i == 78 ||
                    i == 82 || i == 90 || i == 110 || i == 160) {
                    NSMutableData *px = [NSMutableData dataWithLength:W * H * 4];
                    if (charttable_snapshot_rgba(map, px.mutableBytes, px.length) == CHARTTABLE_OK) {
                        const uint8_t *p8 = px.bytes;
                        size_t painted = 0;
                        // The empty frame is the style's background; anything
                        // else is geometry. Sample every 16th pixel.
                        uint8_t br = p8[0], bg = p8[1], bb = p8[2];
                        for (size_t q = 0; q < (size_t)W * H; q += 16) {
                            if (p8[q * 4] != br || p8[q * 4 + 1] != bg || p8[q * 4 + 2] != bb)
                                painted++;
                        }
                        // Reference-free blankness: an empty frame is the
                        // style background edge to edge, so it is UNIFORM,
                        // and every sample matches the corner. The absolute
                        // percentage is not comparable between frames (the
                        // corner is water in one and land in the next) --
                        // near zero is the only reading that means anything.
                        double pct = 100.0 * painted / ((size_t)W * H / 16);
                        NSLog(@"benchzoom: frame %3d %5.1f%% non-uniform%s", i, pct,
                              pct < 1.0 ? "   <-- BLANK" : "");
                    }
                }
                // The number that matches the complaint: how long after
                // the fingers come up before a complete, current chart is
                // on screen.
                if (i >= 80 && settled_at < 0 && charttable_idle(map)) settled_at = i;
                double spent = t2 - t0;
                ms[n++] = spent;
                // Pace to a real 60 Hz: the tile workers are real threads, and
                // a loop that spins faster than the clock never lets them
                // deliver, which would benchmark an empty map.
                if (spent < 16.7) usleep((useconds_t)((16.7 - spent) * 1000));
            }
            for (int i = 1; i < n; i++) {          // insertion sort, n is tiny
                double k = ms[i]; int j = i - 1;
                while (j >= 0 && ms[j] > k) { ms[j + 1] = ms[j]; j--; }
                ms[j + 1] = k;
            }
            double total = 0, over = 0;
            for (int i = 0; i < n; i++) { total += ms[i]; if (ms[i] > 16.7) over++; }
            NSLog(@"benchzoom: settled %d frames (%.0f ms) after the gesture ended",
                  settled_at < 0 ? -1 : settled_at - 80,
                  settled_at < 0 ? -1.0 : (settled_at - 80) * 16.7);
#ifdef USE_TILE57_COMPOSE
            NSLog(@"benchzoom: missing-image %d symbols, %.0f ms (inline, on the frame thread)",
                  g_symbol_n, g_symbol_ms);
#endif
            NSLog(@"benchzoom: tick %.0f ms, render %.0f ms; worst frame %.1f ms "
                  @"(tick %.1f, render %.1f)", tick_ms, render_ms, worst, worst_tick, worst_render);
#ifdef USE_TILE57_COMPOSE
            NSLog(@"benchzoom: compose %d tiles, %.0f ms (off the frame thread)", g_compose_n, g_compose_ms);
#endif
            NSLog(@"benchzoom: %d frames, total %.0f ms, p50 %.2f, p95 %.2f, p99 %.2f, max %.2f, "
                  @"%.1f%% over 16.7 ms",
                  n, total, ms[n / 2], ms[(int)(n * 0.95)], ms[(int)(n * 0.99)], ms[n - 1],
                  100.0 * over / n);
            return 0;
        }

        // CHARTTABLE_ZOOMSHAKE=1: script an eased zoom offscreen and measure
        // the frame-to-frame DISPLACEMENT of the picture's centre. A smooth
        // zoom about the centre shifts it nowhere; a shake shows up as the
        // shift oscillating. Run with CT_MAP_TRACE=1 and the adoption lines
        // interleave, which ties a jump to the scene swap it rode in on.
        if (getenv("CHARTTABLE_ZOOMSHAKE")) {
            const uint32_t W = 1024, H = 768;
            if (charttable_attach_surface(map, CHARTTABLE_NATIVE_NONE, NULL, W, H) != CHARTTABLE_OK) {
                NSLog(@"offscreen surface failed"); return 1;
            }
            charttable_set_pixel_density(map, 1.0f);
            charttable_resize(map, W, H);
            for (int i = 0; i < 4000 && !charttable_idle(map); i++) {
                charttable_tick(map, 16);
                usleep(1000);
            }
            // A 48x48 patch at the exact centre: at dz 0.04 per frame the
            // scale moves its edges under 1 px, so any larger match offset is
            // real displacement, not the zoom.
            enum { FRAMES = 220, PATCH = 48, SHIFT = 6 };
            NSMutableData *px = [NSMutableData dataWithLength:(size_t)W * H * 4];
            static double prev[PATCH][PATCH];
            BOOL havePrev = NO;
            for (int i = 0; i < FRAMES; i++) {
                double zs_dz = strcmp(getenv("CHARTTABLE_ZOOMSHAKE"), "out") == 0 ? -0.04 : 0.04;
                if (i < 100) charttable_zoom_toward(map, zs_dz, W / 2.0f, H / 2.0f);
                charttable_tick(map, 1000.0 / 60.0);
                if (charttable_needs_redraw(map)) charttable_render(map);
                if (charttable_snapshot_rgba(map, px.mutableBytes, px.length) != CHARTTABLE_OK)
                    continue;
                const uint8_t *p8 = px.bytes;
                double cur[PATCH][PATCH];
                for (int y = 0; y < PATCH; y++) {
                    for (int x = 0; x < PATCH; x++) {
                        const uint8_t *q = p8 + (((size_t)H / 2 - PATCH / 2 + y) * W +
                                                 (W / 2 - PATCH / 2 + x)) * 4;
                        cur[y][x] = q[0] * 0.299 + q[1] * 0.587 + q[2] * 0.114;
                    }
                }
                if (havePrev) {
                    int bestDx = 0, bestDy = 0;
                    double best = 1e300;
                    double zeroSad = 0;
                    for (int dy = -SHIFT; dy <= SHIFT; dy++) {
                        for (int dx = -SHIFT; dx <= SHIFT; dx++) {
                            double sad = 0;
                            for (int y = SHIFT; y < PATCH - SHIFT; y++)
                                for (int x = SHIFT; x < PATCH - SHIFT; x++)
                                    sad += fabs(cur[y][x] - prev[y + dy][x + dx]);
                            if (dx == 0 && dy == 0) zeroSad = sad;
                            if (sad < best) { best = sad; bestDx = dx; bestDy = dy; }
                        }
                    }
                    charttable_view cur_v;
                    charttable_get_view(map, &cur_v);
                    // ratio >> 1 with a nonzero shift = the frame truly moved;
                    // ratio ~1 = content changed in place (a rebuild's new
                    // detail) and the shift is noise.
                    NSLog(@"zoomshake: frame %3d zoom %.3f shift %+d,%+d ratio %.2f", i,
                          cur_v.zoom, bestDx, bestDy, best > 0 ? zeroSad / best : 1.0);
                }
                if (getenv("CHARTTABLE_ZOOMSHAKE_RAW") && i >= 35 && i <= 40) {
                    NSString *path = [NSString stringWithFormat:@"%s/raw%03d.bin",
                                      getenv("CHARTTABLE_ZOOMSHAKE_RAW"), i];
                    [px writeToFile:path atomically:NO];
                }
                if (getenv("CHARTTABLE_ZOOMSHAKE_DUMP") && i >= 28 && i <= 40) {
                    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                    CGContextRef ctx = CGBitmapContextCreate(px.mutableBytes, W, H, 8, W * 4, cs,
                                                             kCGImageAlphaPremultipliedLast);
                    CGImageRef img = CGBitmapContextCreateImage(ctx);
                    NSString *path = [NSString stringWithFormat:@"%s/zf%03d.png",
                                      getenv("CHARTTABLE_ZOOMSHAKE_DUMP"), i];
                    NSURL *url = [NSURL fileURLWithPath:path];
                    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
                        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
                    CGImageDestinationAddImage(dst, img, NULL);
                    CGImageDestinationFinalize(dst);
                    CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
                }
                memcpy(prev, cur, sizeof cur);
                havePrev = YES;
                usleep(16000);
            }
            charttable_close(map);
            return 0;
        }

        const char *snap = getenv("CHARTTABLE_SNAPSHOT");
        if (snap) {
            const uint32_t W = 1024, H = 768;
            if (charttable_attach_surface(map, CHARTTABLE_NATIVE_NONE, NULL, W, H) != CHARTTABLE_OK) {
                NSLog(@"offscreen surface failed"); return 1;
            }
            charttable_set_pixel_density(map, 1.0f);
            charttable_resize(map, W, H);
            for (int i = 0; i < 4000 && !charttable_idle(map); i++) {
                int rc = charttable_tick(map, 16);
                if (rc != CHARTTABLE_OK) { NSLog(@"tick failed rc=%d", rc); break; }
                if (getenv("CHARTTABLE_DEBUG_BUILD") && i % 300 == 0)
                    NSLog(@"wait %d: pending %u, idle %d", i, charttable_pending_tiles(map),
                          charttable_idle(map));
                usleep(1000);
            }
            NSMutableData *rgba = [NSMutableData dataWithLength:W * H * 4];
            if (charttable_snapshot_rgba(map, rgba.mutableBytes, rgba.length) != CHARTTABLE_OK) {
                NSLog(@"snapshot failed"); return 1;
            }
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(rgba.mutableBytes, W, H, 8, W * 4, cs,
                                                     kCGImageAlphaPremultipliedLast);
            CGImageRef img = CGBitmapContextCreateImage(ctx);
            NSURL *url = [NSURL fileURLWithPath:@(snap)];
            CGImageDestinationRef dst =
                CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
            CGImageDestinationAddImage(dst, img, NULL);
            CGImageDestinationFinalize(dst);
            CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
            NSLog(@"snapshot -> %s", snap);
            charttable_close(map);
            return 0;
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate *del = [AppDelegate new];
        app.delegate = del;

        NSRect frame = NSMakeRect(0, 0, 1024, 768);
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        win.title = [NSString stringWithFormat:@"charttable — %@", chart.lastPathComponent];
        ChartView *view = [[ChartView alloc] initWithMap:map];
        win.contentView = view;
        [win center];
        [win makeKeyAndOrderFront:nil];
        [win makeFirstResponder:view];
        [app activateIgnoringOtherApps:YES];
        [app run];
        charttable_close(map);
    }
    return 0;
}
