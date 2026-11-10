#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#define PROBE_PLATFORM "UIKit"
static UIWindowScene *probe_scene;
#else
#import <AppKit/AppKit.h>
#define PROBE_PLATFORM "AppKit"
#endif
#import <QuartzCore/QuartzCore.h>
#if TARGET_OS_IPHONE
// The simulator exports these functions but does not ship IOSurface headers.
typedef struct __IOSurface *IOSurfaceRef;
extern CFTypeID IOSurfaceGetTypeID(void);
extern size_t IOSurfaceGetWidth(IOSurfaceRef);
extern size_t IOSurfaceGetHeight(IOSurfaceRef);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef);
extern size_t IOSurfaceGetBytesPerElement(IOSurfaceRef);
extern OSType IOSurfaceGetPixelFormat(IOSurfaceRef);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef);
extern int IOSurfaceLock(IOSurfaceRef, uint32_t, uint32_t *);
extern int IOSurfaceUnlock(IOSurfaceRef, uint32_t, uint32_t *);
#else
#import <IOSurface/IOSurface.h>
#endif
#include <ghostty.h>
#include <assert.h>
#if GRAFTTY_SELECTION_RESIZE_PROBE
extern void graftty_probe_selection_resize(ghostty_surface_t);
#endif
#include <stdio.h>
#include <pthread.h>

// The test transport owns the complete fixture. Production's native bridge
// receives only the prefix and one independent PAGE at a time.
static NSData *transport_fixture;
static size_t transport_offset;
static uint32_t transport_remaining;
static uint16_t transport_screen;
static uint64_t transport_generation;
static uint16_t le16(const uint8_t *p) { return p[0] | (uint16_t)p[1] << 8; }
static uint32_t le32(const uint8_t *p) {
    return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static size_t ready_length(const uint8_t *bytes, size_t len) {
    for (size_t offset = 10; offset + 10 <= len;) {
        size_t size = 10 + (size_t)le32(bytes + offset + 2);
        if (size > len - offset) return 0;
        if (le16(bytes + offset) == 5) return offset + size;
        offset += size;
    }
    return 0;
}
static bool graftty_probe_surface_snapshot_ready(ghostty_surface_t surface, const uint8_t *bytes, size_t len) {
    const size_t prefix = ready_length(bytes, len);
    bool installed = ghostty_surface_snapshot_ready(surface, 1, bytes, prefix ? prefix : len);
    if (installed) {
        transport_fixture = [NSData dataWithBytes:bytes length:len];
        transport_offset = prefix;
        transport_remaining = 0;
        transport_generation = 1;
    }
    return installed;
}
static size_t graftty_probe_surface_snapshot_offset(ghostty_surface_t surface) {
    (void)surface;
    return transport_offset;
}
static int graftty_probe_surface_snapshot_next(ghostty_surface_t surface, size_t *rows) {
    *rows = 0;
    const uint8_t *bytes = transport_fixture.bytes;
    while (!transport_remaining) {
        assert(transport_offset + 10 <= transport_fixture.length);
        const uint16_t tag = le16(bytes + transport_offset);
        if (tag == 6) return 0;
        assert(tag == 4 && le32(bytes + transport_offset + 2) == 6);
        transport_screen = le16(bytes + transport_offset + 10);
        transport_remaining = le32(bytes + transport_offset + 12);
        transport_offset += 16;
    }
    assert(le16(bytes + transport_offset) == 3);
    size_t size = 10 + (size_t)le32(bytes + transport_offset + 2);
    assert(size <= transport_fixture.length - transport_offset);
    int result = ghostty_surface_snapshot_page(surface, transport_generation, transport_screen,
        bytes + transport_offset, size, rows);
    if (result == 1) { transport_offset += size; transport_remaining--; }
    return result;
}
#define graftty_probe_surface_grid_matches ghostty_surface_grid_matches
extern bool graftty_probe_layer_present(void *, IOSurfaceRef);

#if TARGET_OS_IPHONE
typedef UIView ProbeView;
#else
typedef NSView ProbeView;
#endif

static CALayer *render_layer(ProbeView *view) {
#if TARGET_OS_IPHONE
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer isKindOfClass:NSClassFromString(@"IOSurfaceLayer")]) return layer;
    }
    assert(!"missing Ghostty rendering layer");
    return nil;
#else
    return view.layer;
#endif
}

static void layout_renderer(ProbeView *view) {
#if TARGET_OS_IPHONE
    // Match UITerminalView's layout contract: the embedder owns sublayer size.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    render_layer(view).frame = view.bounds;
    [CATransaction commit];
#else
    (void)view;
#endif
}

static void resize_probe(ghostty_surface_t surface, ProbeView *view, uint32_t width, uint32_t height) {
#if TARGET_OS_IPHONE
    view.frame = CGRectMake(0, 0, width, height);
#else
    [view.window setContentSize:NSMakeSize(width, height)];
#endif
    layout_renderer(view);
    ghostty_surface_set_size(surface, width, height);
}

// The presented IOSurface, or NULL until a frame matching the layer's pixel
// size is presented. UIKit may round the backing size by one pixel.
static IOSurfaceRef presented_frame(CALayer *layer) {
    id contents = layer.contents;
    if (!contents || CFGetTypeID((__bridge CFTypeRef)contents) != IOSurfaceGetTypeID()) return NULL;
    IOSurfaceRef frame = (__bridge IOSurfaceRef)contents;
    const size_t width = IOSurfaceGetWidth(frame), height = IOSurfaceGetHeight(frame);
    const size_t expected_width = (size_t)(layer.bounds.size.width * layer.contentsScale);
    const size_t expected_height = (size_t)(layer.bounds.size.height * layer.contentsScale);
    const size_t dw = width > expected_width ? width - expected_width : expected_width - width;
    const size_t dh = height > expected_height ? height - expected_height : expected_height - height;
    const size_t tolerance = TARGET_OS_IPHONE ? 1 : 0;
    return width > 0 && height > 0 && dw <= tolerance && dh <= tolerance ? frame : NULL;
}

// Tick and draw until condition holds, for at most 200 polls 10 ms apart.
static bool wait_until(ghostty_app_t app, ghostty_surface_t surface, bool (^condition)(void)) {
    for (int attempt = 0; attempt < 200; attempt++) {
        ghostty_app_tick(app);
        ghostty_surface_draw(surface);
        if (condition()) return true;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return false;
}

static void write_vt(ghostty_surface_t surface, const char *bytes) {
    ghostty_surface_write_buffer(surface, (const uint8_t *)bytes, strlen(bytes));
}

static void wait_frame(ghostty_app_t app, ghostty_surface_t surface, ProbeView *view) {
    CALayer *layer = render_layer(view);
    assert(layer.bounds.size.width > 0 && layer.bounds.size.height > 0);
    if (!wait_until(app, surface, ^bool { return presented_frame(layer) != NULL; }))
        assert(!"timed out waiting for a presented IOSurface");
}

static void check_stale_frame(ProbeView *view) {
    CALayer *layer = render_layer(view);
    id contents = layer.contents;
    assert(contents && CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID());
    CGRect bounds = layer.bounds;
    CGFloat scale = layer.contentsScale;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.bounds = CGRectMake(0, 0, bounds.size.width / 2, bounds.size.height);
    layer.contents = nil;
    // Deliver the old completed frame after layout changed, before any next
    // draw. This drives the same callback used by asynchronous presentation.
    assert(graftty_probe_layer_present((__bridge void *)layer, (__bridge IOSurfaceRef)contents));
    assert(layer.contents == nil && layer.contentsScale == scale);
    IOSurfaceRef frame = (__bridge IOSurfaceRef)contents;
    layer.bounds = CGRectMake(0, 0, (IOSurfaceGetWidth(frame) - 1) / scale, IOSurfaceGetHeight(frame) / scale);
    assert(graftty_probe_layer_present((__bridge void *)layer, frame));
#if TARGET_OS_IPHONE
    assert(layer.contents == contents); // The one-pixel tolerance remains.
#else
    assert(layer.contents == nil);
#endif
    assert(layer.contentsScale == scale);
    layer.bounds = bounds;
    layer.contents = contents;
    [CATransaction commit];
}

static void wait_grid(ghostty_app_t app, ghostty_surface_t surface, uint16_t cols, uint16_t rows) {
    for (int i = 0; i < 200; i++) {
        ghostty_app_tick(app);
        if (graftty_probe_surface_grid_matches(surface, cols, rows)) return;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    assert(!"timed out waiting for the terminal grid");
}

// Lock and retain a presented BGRA frame for reading, or return NULL before a
// matching frame is presented. Any other pixel format, or a lock failure on a
// presented frame, is a probe defect and aborts with its cause.
static IOSurfaceRef lock_bgra_frame(ProbeView *view) {
    IOSurfaceRef frame = presented_frame(render_layer(view));
    if (!frame) return NULL;
    if (IOSurfaceGetPixelFormat(frame) != 'BGRA' || IOSurfaceGetBytesPerElement(frame) != 4) {
        fprintf(stderr, "unsupported presented frame: format 0x%08x, %zu bytes per element\n",
                (unsigned)IOSurfaceGetPixelFormat(frame), IOSurfaceGetBytesPerElement(frame));
        abort();
    }
    CFRetain(frame);
    const int status = IOSurfaceLock(frame, 1, NULL);
    if (status != 0) {
        fprintf(stderr, "IOSurfaceLock failed: %d\n", status);
        abort();
    }
    return frame;
}

static void unlock_frame(IOSurfaceRef frame) {
    IOSurfaceUnlock(frame, 1, NULL);
    CFRelease(frame);
}

static bool pixel_is(const uint8_t *pixel, bool red) {
    const int dominant = red ? pixel[2] : pixel[0];
    const int opposite = red ? pixel[0] : pixel[2];
    return dominant > (int)pixel[1] + 50 && dominant > opposite + 50;
}

static bool history_pixel_matches(ProbeView *view, bool red) {
    IOSurfaceRef frame = lock_bgra_frame(view);
    if (!frame) return false;
    const uint8_t *pixel = (const uint8_t *)IOSurfaceGetBaseAddress(frame)
        + (IOSurfaceGetHeight(frame) / 2) * IOSurfaceGetBytesPerRow(frame)
        + (IOSurfaceGetWidth(frame) / 2) * 4;
    const bool matches = pixel_is(pixel, red);
    unlock_frame(frame);
    return matches;
}

// Whether any red (or blue) background pixel lies within terminal rows
// [first, last] of a grid `rows` tall. Returns -1 before a frame is presented.
static int band_has_color(ProbeView *view, bool red, uint16_t first, uint16_t last, uint16_t rows) {
    IOSurfaceRef frame = lock_bgra_frame(view);
    if (!frame) return -1;
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(frame);
    const size_t width = IOSurfaceGetWidth(frame), height = IOSurfaceGetHeight(frame);
    const size_t stride = IOSurfaceGetBytesPerRow(frame);
    const size_t top = height * first / rows, bottom = height * (last + 1) / rows;
    int found = 0;
    for (size_t y = top; y < bottom && !found; y++) {
        const uint8_t *row = base + y * stride;
        for (size_t x = 0; x < width; x++) {
            if (pixel_is(row + x * 4, red)) {
                found = 1;
                break;
            }
        }
    }
    unlock_frame(frame);
    return found;
}

// The text of one viewport row, read as a single-row selection so soft wraps
// stay separate, with trailing padding removed. Returns nil when the row cannot
// be read or decoded, which never matches an expected row.
static NSString *viewport_row(ghostty_surface_t surface, uint16_t y, uint16_t cols) {
    const ghostty_selection_s row = {
        .top_left = {.tag = GHOSTTY_POINT_VIEWPORT, .coord = GHOSTTY_POINT_COORD_EXACT, .x = 0, .y = y},
        .bottom_right = {.tag = GHOSTTY_POINT_VIEWPORT, .coord = GHOSTTY_POINT_COORD_EXACT, .x = cols - 1, .y = y},
    };
    ghostty_text_s text = {0};
    if (!ghostty_surface_read_text(surface, row, &text)) return nil;
    NSString *string = [[NSString alloc] initWithBytes:text.text length:text.text_len encoding:NSUTF8StringEncoding];
    ghostty_surface_free_text(surface, &text);
    NSCharacterSet *padding = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (string.length && [padding characterIsMember:[string characterAtIndex:string.length - 1]])
        string = [string substringToIndex:string.length - 1];
    return string;
}

// Whether viewport rows equal expected, with every later row empty.
static bool viewport_rows_are(ghostty_surface_t surface, uint16_t cols, uint16_t rows, NSArray<NSString *> *expected) {
    for (uint16_t y = 0; y < rows; y++) {
        NSString *actual = viewport_row(surface, y, cols);
        if (!actual || ![actual isEqualToString:y < expected.count ? expected[y] : @""]) return false;
    }
    return true;
}

static void dump_viewport_rows(ghostty_surface_t surface, uint16_t cols, uint16_t rows) {
    for (uint16_t y = 0; y < rows; y++) {
        NSString *row = viewport_row(surface, y, cols);
        fprintf(stderr, "  row %2u: %s\n", y, row ? [NSString stringWithFormat:@"\"%@\"", row].UTF8String : "<unreadable>");
    }
}

static bool viewport_contains(ghostty_surface_t surface, const char *needle) {
    const ghostty_selection_s viewport = {
        .top_left = {.tag = GHOSTTY_POINT_VIEWPORT, .coord = GHOSTTY_POINT_COORD_TOP_LEFT},
        .bottom_right = {.tag = GHOSTTY_POINT_VIEWPORT, .coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT},
    };
    ghostty_text_s text = {0};
    if (!ghostty_surface_read_text(surface, viewport, &text)) return false;
    const bool found = text.text && strstr(text.text, needle);
    ghostty_surface_free_text(surface, &text);
    return found;
}

static void check_source_prompt_history(ghostty_app_t app, ghostty_surface_t surface,
                                       ProbeView *view, uint32_t width, uint32_t height) {
    const uint32_t cell_width = ghostty_surface_size(surface).cell_width_px;
    const uint32_t cell_height = ghostty_surface_size(surface).cell_height_px;
    for (int mode = 0; mode < 3; mode++) {
        const int redraw = mode == 0 ? 0 : 1;
        const char *reset = "\x1b" "c";
        write_vt(surface, reset);
        assert(ghostty_surface_set_source_grid(surface, 80, 24));
        char prompt[80];
        snprintf(prompt, sizeof(prompt), "\x1b]133;A;redraw=%d\a" "prompt> \x1b]133;B\a", redraw);
        write_vt(surface, prompt);
        if (mode == 2) {
            const char *command_output = "\x1b]133;C\a";
            write_vt(surface, command_output);
        }
        for (int row = 0; row < 256; row++) {
            char label[40], line[100];
            snprintf(label, sizeof(label), "history-%03d", row);
            snprintf(line, sizeof(line), "\x1b[48;2;220;30;30m%-60s\x1b[0m\r\n", label);
            write_vt(surface, line);
        }
        for (int row = 0; row < 32; row++) {
            char label[40], line[100];
            snprintf(label, sizeof(label), "recent-%03d", row);
            snprintf(line, sizeof(line), "\x1b[48;2;30;30;220m%-60s\x1b[0m\r\n", label);
            write_vt(surface, line);
        }
        const uint16_t grids[][2] = {{80, 20}, {80, 24}, {76, 24}, {80, 24}};
        uint16_t previous_cols = 80;
        for (size_t index = 0; index < sizeof(grids) / sizeof(grids[0]); index++) {
            ghostty_action_scrollbar_s before = {0}, after = {0};
            ghostty_surface_read_scrollbar(surface, &before);
            resize_probe(surface, view, width - (80 - grids[index][0]) * cell_width,
                         height - (24 - grids[index][1]) * cell_height);
            assert(ghostty_surface_set_source_grid(surface, grids[index][0], grids[index][1]));
            wait_grid(app, surface, grids[index][0], grids[index][1]);
            ghostty_surface_read_scrollbar(surface, &after);
            assert(after.total > after.len);
            if (previous_cols == grids[index][0]) assert(after.total == before.total);
            previous_cols = grids[index][0];
            ghostty_text_s oldest = {0};
            assert(ghostty_surface_read_history(surface, 1, 1, &oldest));
            assert(oldest.text && strstr(oldest.text, "history-000"));
            ghostty_surface_free_text(surface, &oldest);
            assert(ghostty_surface_binding_action(surface, "scroll_to_bottom", strlen("scroll_to_bottom")));
            const bool blue = wait_until(app, surface, ^bool { return viewport_contains(surface, "recent-") && history_pixel_matches(view, false); });
            assert(blue);
            assert(ghostty_surface_binding_action(surface, "scroll_to_top", strlen("scroll_to_top")));
            const bool visible = wait_until(app, surface, ^bool { return viewport_contains(surface, "history-000") && history_pixel_matches(view, true); });
            assert(visible);
        }
        // Source-grid suppression must not disable ordinary shell prompt redraw.
        const char *ordinary = "\x1b]133;C\a\r\n\x1b]133;A\aordinary-prompt> \x1b]133;B\a";
        write_vt(surface, ordinary);
        assert(ghostty_surface_binding_action(surface, "scroll_to_bottom", strlen("scroll_to_bottom")));
        const bool ordinary_shown = wait_until(app, surface, ^bool { return viewport_contains(surface, "ordinary-prompt>"); });
        assert(ordinary_shown);
        assert(ghostty_surface_clear_source_grid(surface));
        resize_probe(surface, view, width + cell_width, height);
        wait_grid(app, surface, 81, 24);
        assert(viewport_contains(surface, "ordinary-prompt>") == (redraw == 0));
        ghostty_text_s oldest = {0};
        assert(ghostty_surface_read_history(surface, 1, 1, &oldest));
        assert(oldest.text && strstr(oldest.text, "history-000"));
        ghostty_surface_free_text(surface, &oldest);
        resize_probe(surface, view, width, height);
        wait_grid(app, surface, 80, 24);
        printf(PROBE_PLATFORM " source-grid prompt history: redraw=%d semantic=%s text/pixels/rows/shell-control PASS\n",
               redraw, mode == 2 ? "output" : "input");
    }
    const char *reset = "\x1b" "c";
    write_vt(surface, reset);
}

// zmx resizes its own terminal with shell prompt redraw suppressed, so a mirror
// pinned to its source grid must reflow a wrapped prompt instead of clearing
// it, then show exactly what the shell redisplays. These rows match bundled
// zmx 1.0.1-ga35f00a-graftty11 for every OSC 133 redraw mode.
static void check_source_prompt_reflow(ghostty_app_t app, ghostty_surface_t surface, ProbeView *view) {
    enum { wide = 80, narrow = 40, rows = 24 };
    NSArray<NSString *> *before = @[
        @"prior> echo", @"COMPLETED-OUTPUT",
        @"OLD-PROMPT-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg",
        @"hijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxy",
        @"zABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789input-tail",
    ];
    NSArray<NSString *> *narrowed = @[
        @"prior> echo", @"COMPLETED-OUTPUT", @"OLD-PROMPT-abcdefghijklmnopqrstuvwxyzABC",
        @"DEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg", @"hijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTU",
        @"VWXYZ0123456789abcdefghijklmnopqrstuvwxy", @"zABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789inp", @"ut-tail",
    ];
    NSMutableArray<NSString *> *redrawn = [narrowed mutableCopy];
    redrawn[7] = @"short> x";
    NSArray<NSString *> *erased = @[@"prior> echo", @"COMPLETED-OUTPUT", @"clean> y"];
    NSArray<NSString *> *completed = @[@"prior> echo", @"COMPLETED-OUTPUT", @"clean> y", @"AFTER-OUTPUT", @"next>"];
    // The 197-cell red prompt plus its 10-cell input spans rows 2-4 at 80
    // columns and rows 2-7 at 40. Bands divide the frame height evenly, so
    // window padding lets row 4 spill into the row 5 band; row 6 is clear of
    // the old rows, so red there proves a reflowed frame. After the explicit
    // erase, row 2 holds the blue "clean> " prompt.
    enum { reflow_row = 6, clean_row = 2 };
    const char *modes[] = {"0", "1", "last"};
    for (size_t mode = 0; mode < sizeof(modes) / sizeof(modes[0]); mode++) {
        char bytes[512];
        write_vt(surface, "\x1b" "c");
        assert(ghostty_surface_set_source_grid(surface, wide, rows));
        snprintf(bytes, sizeof(bytes),
                 "\x1b]133;A;redraw=%s\aprior> \x1b]133;B\aecho\x1b]133;C\a\r\nCOMPLETED-OUTPUT\r\n\x1b]133;D;0\a"
                 "\x1b]133;A;redraw=%s\a\x1b[48;2;220;30;30mOLD-PROMPT-"
                 "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                 "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                 "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                 "\x1b[0m\x1b]133;B\ainput-tail",
                 modes[mode], modes[mode]);
        write_vt(surface, bytes);
        if (!wait_until(app, surface, ^bool {
                return viewport_rows_are(surface, wide, rows, before) && band_has_color(view, true, 2, 4, rows) == 1
                    && band_has_color(view, true, reflow_row, reflow_row, rows) == 0;
            })) {
            fprintf(stderr, "source-grid reflow redraw=%s before\n", modes[mode]);
            dump_viewport_rows(surface, wide, rows);
            abort();
        }

        // zmx narrows the source grid while the physical view stays the same.
        assert(ghostty_surface_set_source_grid(surface, narrow, rows));
        wait_grid(app, surface, narrow, rows);
        struct { const char *phase; const char *input; NSArray<NSString *> *rows; bool red; bool blue; } steps[] = {
            {"narrowed", "", narrowed, true, false},
            {"minimal redisplay", "\r\x1b]133;A\ashort> \x1b]133;B\ax", redrawn, true, false},
            {"explicit-erase redisplay",
             "\x1b[3;1H\x1b[J\x1b]133;A\a\x1b[48;2;30;30;220mclean> \x1b[0m\x1b]133;B\ay", erased, false, true},
            {"completion", "\x1b]133;C\a\r\nAFTER-OUTPUT\r\n\x1b]133;D;0\a\x1b]133;A\anext> \x1b]133;B\a",
             completed, false, true},
        };
        for (size_t step = 0; step < sizeof(steps) / sizeof(steps[0]); step++) {
            write_vt(surface, steps[step].input);
            NSArray<NSString *> *expected = steps[step].rows;
            const bool red = steps[step].red, blue = steps[step].blue;
            if (!wait_until(app, surface, ^bool {
                    if (!viewport_rows_are(surface, narrow, rows, expected)) return false;
                    const int red_now = red ? band_has_color(view, true, reflow_row, reflow_row, rows)
                                            : band_has_color(view, true, 0, rows - 1, rows);
                    return red_now == (red ? 1 : 0)
                        && (!blue || band_has_color(view, false, clean_row, clean_row, rows) == 1);
                })) {
                fprintf(stderr, "source-grid reflow redraw=%s %s: expected red %s%s\n", modes[mode],
                        steps[step].phase, red ? "in reflowed rows" : "absent", blue ? ", blue clean prompt" : "");
                dump_viewport_rows(surface, narrow, rows);
                abort();
            }
        }

        // Ordinary-shell control: releasing the pin while the physical grid is
        // wider takes Ghostty's normal resize, which clears the current prompt
        // for a redraw-capable shell. Completed output survives in every mode.
        assert(ghostty_surface_clear_source_grid(surface));
        wait_grid(app, surface, wide, rows);
        const bool shell_redraws = strcmp(modes[mode], "0") != 0;
        NSArray<NSString *> *unpinned = shell_redraws ? [completed subarrayWithRange:NSMakeRange(0, 4)] : completed;
        if (!wait_until(app, surface, ^bool { return viewport_rows_are(surface, wide, rows, unpinned); })) {
            fprintf(stderr, "source-grid reflow redraw=%s mismatched unpin\n", modes[mode]);
            dump_viewport_rows(surface, wide, rows);
            abort();
        }
        printf(PROBE_PLATFORM " source-grid prompt reflow: redraw=%s wrap/redisplay/erase/unpin PASS\n", modes[mode]);
    }
    write_vt(surface, "\x1b" "c");
}

static void wakeup(void *data) { (void)data; }
static bool action(ghostty_app_t app, ghostty_target_s target, ghostty_action_s event) {
    (void)app; (void)target; (void)event; return false;
}
typedef struct {
    pthread_mutex_t mutex;
    uint8_t bytes[8192];
    size_t len;
} OutputCapture;

static void output(void *data, const uint8_t *bytes, size_t len) {
    OutputCapture *capture = data;
    pthread_mutex_lock(&capture->mutex);
    assert(len <= sizeof(capture->bytes) - capture->len);
    memcpy(capture->bytes + capture->len, bytes, len);
    capture->len += len;
    pthread_mutex_unlock(&capture->mutex);
}

static bool expect_output(ghostty_app_t app, ghostty_surface_t surface, OutputCapture *capture,
    const char *input, const char *expected, bool terminal_output) {
    pthread_mutex_lock(&capture->mutex);
    capture->len = 0;
    pthread_mutex_unlock(&capture->mutex);
    if (terminal_output) ghostty_surface_write_buffer(surface, (const uint8_t *)input, strlen(input));
    else ghostty_surface_text(surface, input, strlen(input));
    const size_t expected_len = strlen(expected);
    for (int i = 0; i < 200; i++) {
        ghostty_app_tick(app);
        pthread_mutex_lock(&capture->mutex);
        bool matches = capture->len == expected_len && memcmp(capture->bytes, expected, expected_len) == 0;
        pthread_mutex_unlock(&capture->mutex);
        if (matches) return true;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    pthread_mutex_lock(&capture->mutex);
    fprintf(stderr, "output mismatch: expected %zu bytes, received %zu:", expected_len, capture->len);
    for (size_t i = 0; i < capture->len; i++) fprintf(stderr, " %02x", capture->bytes[i]);
    fprintf(stderr, "\n");
    pthread_mutex_unlock(&capture->mutex);
    return false;
}
static ghostty_clipboard_read_result_e read_clipboard(void *data, ghostty_clipboard_e clipboard,
    void *state, const char *const *mimes, size_t count, bool prompt) {
    (void)data; (void)clipboard; (void)state; (void)mimes; (void)count; (void)prompt;
    return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
}
static void confirm_clipboard(void *data, const ghostty_clipboard_confirm_s *confirm,
    void *state, ghostty_clipboard_request_e request) {
    (void)data; (void)confirm; (void)state; (void)request;
}
static void write_clipboard(void *data, ghostty_clipboard_e clipboard,
    const ghostty_clipboard_content_s *content, size_t count, bool confirm) {
    (void)data; (void)clipboard; (void)content; (void)count; (void)confirm;
}

static int run_probe(int argc, char **argv, NSData *snapshot, NSData *mode_snapshot) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        assert(snapshot.length > 0);
        assert(mode_snapshot.length > 0);
        assert(ghostty_init(argc, argv) == 0);
#if !TARGET_OS_IPHONE
        [NSApplication sharedApplication];
#endif
        for (int scenario = 0; scenario < 10; scenario++) {
            NSData *fixture = scenario == 6 ? mode_snapshot : snapshot;
            const bool needs_recovery = (scenario >= 2 && scenario <= 4) || scenario >= 8;
            const bool limited = scenario == 7;
#if TARGET_OS_IPHONE
            UIWindow *window = [[UIWindow alloc] initWithWindowScene:probe_scene];
            window.frame = UIScreen.mainScreen.bounds;
            window.rootViewController = [UIViewController new];
            UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 800, 480)];
            [window.rootViewController.view addSubview:view];
            [window makeKeyAndVisible];
#else
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 480)
                styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            NSView *view = window.contentView;
            view.wantsLayer = YES;
            window.title = @"Graftty snapshot renderer experiment";
#endif
            ghostty_config_t config = ghostty_config_new();
            NSString *config_path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"graftty-production-probe.conf"];
            NSString *config_text = limited ? @"scrollback-limit-bytes = 4096\n" : @"scrollback-limit-bytes = unlimited\n";
            config_text = [config_text stringByAppendingString:@"foreground = #12ab34\npalette = 1=#456789\n"];
            assert([config_text writeToFile:config_path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
            ghostty_config_load_file(config, config_path.UTF8String);
            ghostty_config_finalize(config);
            ghostty_runtime_config_s runtime = {
                .wakeup_cb = wakeup, .action_cb = action, .read_clipboard_cb = read_clipboard,
                .confirm_read_clipboard_cb = confirm_clipboard, .write_clipboard_cb = write_clipboard,
            };
            ghostty_app_t app = ghostty_app_new(&runtime, config);
            assert(app);
            ghostty_surface_config_s options = ghostty_surface_config_new();
#if TARGET_OS_IPHONE
            options.platform_tag = GHOSTTY_PLATFORM_IOS;
            options.platform.ios.uiview = (__bridge void *)view;
#else
            options.platform_tag = GHOSTTY_PLATFORM_MACOS;
            options.platform.macos.nsview = (__bridge void *)view;
#endif
            options.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED;
            OutputCapture capture = {0};
            assert(pthread_mutex_init(&capture.mutex, NULL) == 0);
            options.receive_userdata = &capture;
            options.receive_buffer = output;
            ghostty_surface_t surface = ghostty_surface_new(app, &options);
            assert(surface);
            resize_probe(surface, view, 800, 480);
            ghostty_surface_size_s size = ghostty_surface_size(surface);
            const uint32_t width = 800 + (80 - size.columns) * size.cell_width_px;
            const uint32_t height = 480 + (24 - size.rows) * size.cell_height_px;
            resize_probe(surface, view, width, height);
#if !TARGET_OS_IPHONE
            [window orderFront:nil];
#endif
            wait_grid(app, surface, 80, 24);
            if (scenario == 0) {
                check_source_prompt_history(app, surface, view, width, height);
                check_source_prompt_reflow(app, surface, view);
            }
            // A truncated READY must leave the original surface usable.
            assert(!graftty_probe_surface_snapshot_ready(surface, fixture.bytes, 16));
            assert(graftty_probe_surface_snapshot_ready(surface, fixture.bytes, fixture.length));
            // Repeating an attachment generation is stale.
            assert(!graftty_probe_surface_snapshot_ready(surface, fixture.bytes, fixture.length));
            size_t rejected_rows = 123;
            assert(ghostty_surface_snapshot_page(surface, 99, 0, fixture.bytes, 16, &rejected_rows) == 4);
            assert(rejected_rows == 0);
            assert(!ghostty_surface_snapshot_near_top(surface, 99, 0, UINT32_MAX));
            assert(!ghostty_surface_snapshot_near_top(surface, 1, 1, UINT32_MAX));
            const char *live = "msurface-live-output\r\n";
            ghostty_surface_write_buffer(surface, (const uint8_t *)live, strlen(live));
            for (int i = 0; i < 20; i++) {
                ghostty_app_tick(app);
                ghostty_surface_draw(surface);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
            assert(expect_output(app, surface, &capture, "\x1b]10;?\x1b\\", "\x1b]10;rgb:1212/abab/3434\x1b\\", true));
            assert(expect_output(app, surface, &capture, "\x1b]4;1;?\x1b\\", "\x1b]4;1;rgb:4545/6767/8989\x1b\\", true));
            if (scenario == 6) {
                bool restored_input = expect_output(app, surface, &capture, "\r", "\r\n", false);
                const char *disable = "\x1b[20l";
                ghostty_surface_write_buffer(surface, (const uint8_t *)disable, strlen(disable));
                bool disabled_input = expect_output(app, surface, &capture, "a\rb\r", "a\rb\r", false);
                const char *enable = "\x1b[20h";
                ghostty_surface_write_buffer(surface, (const uint8_t *)enable, strlen(enable));
                bool enabled_input = expect_output(app, surface, &capture, "a\rb\r", "a\r\nb\r\n", false);
                char long_input[2050], long_expected[2053];
                memset(long_input, 'x', sizeof(long_input) - 1);
                long_input[1023] = long_input[1024] = long_input[2048] = '\r';
                long_input[2049] = '\0';
                size_t expected_pos = 0;
                for (size_t i = 0; i < sizeof(long_input) - 1; i++) {
                    long_expected[expected_pos++] = long_input[i];
                    if (long_input[i] == '\r') long_expected[expected_pos++] = '\n';
                }
                long_expected[expected_pos] = '\0';
                bool chunked_input = expect_output(app, surface, &capture, long_input, long_expected, false);
                // No closing reset is sent. The ordinary one-second watchdog
                // must release synchronized output restored by the checkpoint.
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
                bool sync_timeout = expect_output(app, surface, &capture, "\x1b[?2026$p", "\x1b[?2026;2$y", true);
                assert(restored_input && disabled_input && enabled_input && chunked_input && sync_timeout);
            }
            wait_frame(app, surface, view);
            if (scenario == 0) check_stale_frame(view);
            ghostty_selection_s selection = {
                .top_left = {.tag = GHOSTTY_POINT_SCREEN, .coord = GHOSTTY_POINT_COORD_TOP_LEFT},
                .bottom_right = {.tag = GHOSTTY_POINT_SCREEN, .coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT},
            };
            ghostty_text_s text = {0};
            assert(ghostty_surface_read_text(surface, selection, &text));
            assert(text.text && strstr(text.text, "surface-live-output"));
            assert(strstr(text.text, "row-099999"));
            assert(!strstr(text.text, "row-000000"));
            const size_t first_page_offset = ready_length(fixture.bytes, fixture.length) + 16;
            const uint8_t *first_page = (const uint8_t *)fixture.bytes + first_page_offset;
            const size_t first_page_len = 10 + le32(first_page + 2);
            NSMutableData *bad_page = [NSMutableData dataWithBytes:first_page length:first_page_len];
            ((uint8_t *)bad_page.mutableBytes)[first_page_len - 1] ^= 1;
            assert(ghostty_surface_snapshot_page(surface, 1, 0, bad_page.bytes, bad_page.length, &rejected_rows) == -1);
            assert(rejected_rows == 0);
            assert(ghostty_surface_snapshot_page(surface, 1, 0, first_page, first_page_len - 1, &rejected_rows) == -1);
            ghostty_text_s unchanged = {0};
            assert(ghostty_surface_read_text(surface, selection, &unchanged));
            assert(unchanged.text_len == text.text_len && memcmp(unchanged.text, text.text, text.text_len) == 0);
            ghostty_surface_free_text(surface, &unchanged);
            ghostty_surface_free_text(surface, &text);
            ghostty_text_s selected_before = {0}, anchor_before = {0};
            ghostty_selection_s anchor_range = {
                .top_left = {.tag = GHOSTTY_POINT_VIEWPORT, .coord = GHOSTTY_POINT_COORD_EXACT},
                .bottom_right = {.tag = GHOSTTY_POINT_VIEWPORT, .coord = GHOSTTY_POINT_COORD_EXACT, .x = 9},
            };
            size_t pages = 0, applied = 0;
            if (scenario == 4) {
                assert(graftty_probe_surface_snapshot_next(surface, &applied) == 1 && applied > 0);
                pages++;
            }
            if (scenario == 0 || scenario == 4) {
                assert(ghostty_surface_binding_action(surface, "scroll_to_top", strlen("scroll_to_top")));
                assert(ghostty_surface_binding_action(surface, "select_all", strlen("select_all")));
                // Scroll actions are queued to Ghostty's I/O thread. Observe the
                // requested viewport before taking an anchor or fetching pages.
                ghostty_selection_s first_row = anchor_range;
                first_row.top_left.tag = GHOSTTY_POINT_SCREEN;
                first_row.bottom_right.tag = GHOSTTY_POINT_SCREEN;
                ghostty_text_s expected_top = {0};
                assert(ghostty_surface_read_text(surface, first_row, &expected_top));
                bool at_top = false;
                for (int i = 0; i < 200; i++) {
                    ghostty_app_tick(app);
                    ghostty_text_s current_top = {0};
                    assert(ghostty_surface_read_text(surface, anchor_range, &current_top));
                    at_top = current_top.text_len == expected_top.text_len &&
                        memcmp(current_top.text, expected_top.text, current_top.text_len) == 0;
                    ghostty_surface_free_text(surface, &current_top);
                    if (at_top) break;
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                }
                ghostty_surface_free_text(surface, &expected_top);
                assert(at_top);
                assert(ghostty_surface_snapshot_near_top(surface, 1, 0, 0));
                assert(ghostty_surface_read_selection(surface, &selected_before));
#if GRAFTTY_SELECTION_RESIZE_PROBE
                graftty_probe_selection_resize(surface);
                ghostty_text_s after_invalid_click = {0};
                assert(ghostty_surface_read_selection(surface, &after_invalid_click));
                assert(after_invalid_click.text_len == selected_before.text_len);
                assert(memcmp(after_invalid_click.text, selected_before.text, selected_before.text_len) == 0);
                ghostty_surface_free_text(surface, &after_invalid_click);
#endif
                assert(ghostty_surface_read_text(surface, anchor_range, &anchor_before));
                assert(anchor_before.text_len == 10);
            }
            if (scenario == 1) {
                const char *alternate = "\x1b[?1049halt-screen";
                ghostty_surface_write_buffer(surface, (const uint8_t *)alternate, strlen(alternate));
            } else if (scenario >= 8) {
                const char *invalidate = scenario == 8 ? "\x1b" "c" : "\x1b[3J";
                ghostty_surface_write_buffer(surface, (const uint8_t *)invalidate, strlen(invalidate));
            } else if (needs_recovery) {
                resize_probe(surface, view, width - 40 * size.cell_width_px, height);
                wait_grid(app, surface, 40, 24);
                if (scenario == 3) {
                    // No history call sees the intermediate width. Checking
                    // only current columns would accept stale pages again.
                    resize_probe(surface, view, width, height);
                    wait_grid(app, surface, 80, 24);
                }
            } else if (scenario == 5) {
                resize_probe(surface, view, width, height + 4 * size.cell_height_px);
                wait_grid(app, surface, 80, 28);
            }
            const size_t offset_before = graftty_probe_surface_snapshot_offset(surface);
            assert(offset_before < fixture.length);
            int status;
            while ((status = graftty_probe_surface_snapshot_next(surface, &applied)) == 1) {
                assert(!needs_recovery && applied > 0);
                pages++;
                ghostty_app_tick(app);
                ghostty_surface_draw(surface);
            }
            if (limited) {
                assert(status == 3 && applied == 0);
                const size_t limit_offset = transport_offset;
                assert(graftty_probe_surface_snapshot_next(surface, &applied) == 3 && applied == 0);
                assert(transport_offset == limit_offset);
            } else if (needs_recovery) {
                assert(status == 2 && applied == 0);
                assert(pages == (scenario == 4 ? 1 : 0));
                // Retrying cannot consume the old cursor or turn recovery
                // into completion. Live output remains independently usable.
                for (int retry = 0; retry < 3; retry++) {
                    assert(graftty_probe_surface_snapshot_next(surface, &applied) == 2 && applied == 0);
                    // Only the first call may read HISTORY's 10-byte record
                    // header and 6-byte payload. It never reads the PAGE.
                    const size_t manifest_bytes = scenario == 4 ? 0 : 16;
                    assert(graftty_probe_surface_snapshot_offset(surface) == offset_before + manifest_bytes);
                }
            } else {
                assert(status == 0 && pages > 1);
                assert(graftty_probe_surface_snapshot_next(surface, &applied) == 0 && applied == 0);
                if (scenario == 5) {
                    resize_probe(surface, view, width - 40 * size.cell_width_px, height);
                    wait_grid(app, surface, 40, 24);
                    assert(graftty_probe_surface_snapshot_next(surface, &applied) == 0 && applied == 0);
                }
            }
            if (scenario == 0 || scenario == 4) {
                ghostty_text_s after = {0};
                assert(ghostty_surface_read_selection(surface, &after));
                assert(after.text_len == selected_before.text_len);
                assert(memcmp(after.text, selected_before.text, after.text_len) == 0);
                ghostty_surface_free_text(surface, &after);
                assert(ghostty_surface_read_text(surface, anchor_range, &after));
                assert(after.text_len == anchor_before.text_len);
                assert(memcmp(after.text, anchor_before.text, after.text_len) == 0);
                ghostty_surface_free_text(surface, &after);
                ghostty_surface_free_text(surface, &anchor_before);
                ghostty_surface_free_text(surface, &selected_before);
            }
            if (scenario == 1) {
                const char *primary = "\x1b[?1049l";
                ghostty_surface_write_buffer(surface, (const uint8_t *)primary, strlen(primary));
            } else if (needs_recovery) {
                const char *continued = "after-resize\r\n";
                ghostty_surface_write_buffer(surface, (const uint8_t *)continued, strlen(continued));
            }
            assert(ghostty_surface_read_text(surface, selection, &text));
            const char *cursor = text.text;
            if (!needs_recovery && !limited) {
                for (int row = 0; row < 100000; row++) {
                    char expected[32];
                    snprintf(expected, sizeof(expected), "row-%06d\n", row);
                    assert(strncmp(cursor, expected, strlen(expected)) == 0);
                    cursor += strlen(expected);
                }
                assert(strncmp(cursor, "surface-live-output", strlen("surface-live-output")) == 0);
                cursor += strlen("surface-live-output");
                while (*cursor) assert(*cursor++ == '\n');
            } else {
                if (scenario != 8) assert(strstr(text.text, "surface-live-output"));
                if (needs_recovery) assert(strstr(text.text, "after-resize"));
                assert(!strstr(text.text, "row-000000"));
            }
            ghostty_surface_free_text(surface, &text);
            wait_frame(app, surface, view);
            // Replace a retained, selected surface with another attachment.
            // Old page/selection pins must not leak into the new terminal.
            resize_probe(surface, view, width, height);
            wait_grid(app, surface, 80, 24);
            assert(ghostty_surface_binding_action(surface, "select_all", strlen("select_all")));
            assert(ghostty_surface_snapshot_ready(surface, 2, fixture.bytes, ready_length(fixture.bytes, fixture.length)));
            assert(!ghostty_surface_has_selection(surface));
            assert(ghostty_surface_snapshot_page(surface, 1, 0, fixture.bytes, 16, &applied) == 4);
            assert(!ghostty_surface_snapshot_ready(surface, 1, fixture.bytes, ready_length(fixture.bytes, fixture.length)));
            assert(ghostty_surface_snapshot_ready(surface, 3, fixture.bytes, ready_length(fixture.bytes, fixture.length)));
            const char *replacement_live = "mretained-replacement";
            ghostty_surface_write_buffer(surface, (const uint8_t *)replacement_live, strlen(replacement_live));
            assert(ghostty_surface_read_text(surface, selection, &text));
            assert(strstr(text.text, "retained-replacement"));
            assert(!strstr(text.text, "surface-live-output"));
            ghostty_surface_free_text(surface, &text);
            assert(ghostty_surface_binding_action(surface, "select_all", strlen("select_all")));
            assert(ghostty_surface_has_selection(surface));
            assert(ghostty_surface_binding_action(surface, "clear_selection", strlen("clear_selection")));
            assert(!ghostty_surface_has_selection(surface));
            wait_frame(app, surface, view);
            ghostty_surface_free(surface);
            assert(pthread_mutex_destroy(&capture.mutex) == 0);
            ghostty_app_free(app);
            ghostty_config_free(config);
#if TARGET_OS_IPHONE
            window.hidden = YES;
#else
            [window orderOut:nil];
#endif
            printf(PROBE_PLATFORM " snapshot surface: scenario=%d pages=%zu READY/live/draw/destroy PASS%s\n",
                scenario, pages, limited ? "; local retention limit preserved" : needs_recovery ? "; recovery required without consuming pending pages" : "; all 100000 rows in order");
        }
    }
    return 0;
}

#if TARGET_OS_IPHONE
static int probe_argc;
static char **probe_argv;

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeAppDelegate
@end

@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    probe_scene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:probe_scene];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"surface-fixture" ofType:@"bin"];
        NSData *snapshot = [NSData dataWithContentsOfFile:path];
        NSString *mode_path = [[NSBundle mainBundle] pathForResource:@"surface-modes" ofType:@"bin"];
        exit(run_probe(probe_argc, probe_argv, snapshot, [NSData dataWithContentsOfFile:mode_path]));
    });
}
@end

int main(int argc, char **argv) {
    probe_argc = argc;
    probe_argv = argv;
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
    }
}
#else
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        NSData *snapshot = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSData *mode_snapshot = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
        return run_probe(argc, argv, snapshot, mode_snapshot);
    }
}
#endif
