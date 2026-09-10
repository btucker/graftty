#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#define PROBE_PLATFORM "UIKit"
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

static void wait_frame(ghostty_app_t app, ghostty_surface_t surface, ProbeView *view) {
    CALayer *layer = render_layer(view);
    assert(layer.bounds.size.width > 0 && layer.bounds.size.height > 0);
    for (int i = 0; i < 200; i++) {
        ghostty_app_tick(app);
        ghostty_surface_draw(surface);
        id contents = layer.contents;
        if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
            IOSurfaceRef frame = (__bridge IOSurfaceRef)contents;
            size_t width = IOSurfaceGetWidth(frame), height = IOSurfaceGetHeight(frame);
            size_t expected_width = (size_t)(layer.bounds.size.width * layer.contentsScale);
            size_t expected_height = (size_t)(layer.bounds.size.height * layer.contentsScale);
            size_t dw = width > expected_width ? width - expected_width : expected_width - width;
            size_t dh = height > expected_height ? height - expected_height : expected_height - height;
            size_t tolerance = TARGET_OS_IPHONE ? 1 : 0;
            if (width > 0 && height > 0 && dw <= tolerance && dh <= tolerance) return;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
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
            UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
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
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"surface-fixture" ofType:@"bin"];
        NSData *snapshot = [NSData dataWithContentsOfFile:path];
        NSString *mode_path = [[NSBundle mainBundle] pathForResource:@"surface-modes" ofType:@"bin"];
        exit(run_probe(probe_argc, probe_argv, snapshot, [NSData dataWithContentsOfFile:mode_path]));
    });
    return YES;
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
