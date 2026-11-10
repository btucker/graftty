#import <AppKit/AppKit.h>
#include <ghostty.h>
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static char opened[8192];
static size_t opened_count;
static ghostty_action_open_url_kind_e opened_kind;
static pthread_mutex_t output_mutex = PTHREAD_MUTEX_INITIALIZER;
static char output_bytes[8192];
static size_t output_len;

static void wakeup(void *data) { (void)data; }
static bool action(ghostty_app_t app, ghostty_target_s target, ghostty_action_s event) {
    (void)app; (void)target;
    if (event.tag == GHOSTTY_ACTION_OPEN_URL) {
        ghostty_action_open_url_s url = event.action.open_url;
        assert(url.len < sizeof(opened));
        memcpy(opened, url.url, url.len);
        opened[url.len] = 0;
        opened_kind = url.kind;
        opened_count++;
    }
    // Capture all opens. Never dispatch a browser, editor, or system opener.
    return true;
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
static void output(void *data, const uint8_t *bytes, size_t len) {
    (void)data;
    pthread_mutex_lock(&output_mutex);
    assert(len <= sizeof(output_bytes) - output_len);
    memcpy(output_bytes + output_len, bytes, len);
    output_len += len;
    pthread_mutex_unlock(&output_mutex);
}
static void tick(ghostty_app_t app) {
    ghostty_app_tick(app);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static bool contains(ghostty_surface_t surface, const char *expected) {
    ghostty_selection_s all = {
        .top_left = {.tag = GHOSTTY_POINT_SCREEN, .coord = GHOSTTY_POINT_COORD_TOP_LEFT},
        .bottom_right = {.tag = GHOSTTY_POINT_SCREEN, .coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT},
    };
    ghostty_text_s text = {0};
    assert(ghostty_surface_read_text(surface, all, &text));
    bool found = text.text && strstr(text.text, expected);
    ghostty_surface_free_text(surface, &text);
    return found;
}
static size_t ready_length(NSData *data) {
    const uint8_t *bytes = data.bytes;
    for (size_t offset = 10; offset + 10 <= data.length;) {
        uint16_t tag = bytes[offset] | (uint16_t)bytes[offset + 1] << 8;
        uint32_t len = 0;
        for (int i = 0; i < 4; i++) len |= (uint32_t)bytes[offset + 2 + i] << (i * 8);
        size_t next = offset + 10 + len;
        assert(next <= data.length);
        if (tag == 5) return next;
        offset = next;
    }
    assert(!"missing READY");
    return 0;
}
static void click(ghostty_surface_t surface, bool drag) {
    ghostty_surface_size_s size = ghostty_surface_size(surface);
    const double x = size.cell_width_px * 2.5, y = size.cell_height_px * .5;
    // Move off the previous hit cell so repeated restores refresh hover state.
    ghostty_surface_mouse_pos(surface, x + size.cell_width_px * 10, y, GHOSTTY_MODS_SUPER);
    ghostty_surface_mouse_pos(surface, x, y, GHOSTTY_MODS_SUPER);
    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER);
    if (drag) ghostty_surface_mouse_pos(surface, x + size.cell_width_px * 3, y, GHOSTTY_MODS_SUPER);
    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 5 || argc == 6);
        const bool drag = strcmp(argv[4], "drag") == 0;
        const bool live = strcmp(argv[4], "live") == 0;
        assert(ghostty_init(argc, argv) == 0);
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 480)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.contentView.wantsLayer = YES;
        ghostty_config_t config = ghostty_config_new();
        ghostty_config_finalize(config);
        ghostty_runtime_config_s runtime = {
            .wakeup_cb = wakeup, .action_cb = action, .read_clipboard_cb = read_clipboard,
            .confirm_read_clipboard_cb = confirm_clipboard, .write_clipboard_cb = write_clipboard,
        };
        ghostty_app_t app = ghostty_app_new(&runtime, config);
        assert(app);
        ghostty_surface_config_s options = ghostty_surface_config_new();
        options.platform_tag = GHOSTTY_PLATFORM_MACOS;
        options.platform.macos.nsview = (__bridge void *)window.contentView;
        options.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED;
        options.receive_buffer = output;
        ghostty_surface_t surface = ghostty_surface_new(app, &options);
        assert(surface);
        ghostty_surface_set_size(surface, 800, 480);
        ghostty_surface_size_s initial = ghostty_surface_size(surface);
        ghostty_surface_set_size(surface, 800 + (80 - initial.columns) * initial.cell_width_px,
            480 + (24 - initial.rows) * initial.cell_height_px);
        for (int i = 0; i < 400 && !ghostty_surface_grid_matches(surface, 80, 24); i++) tick(app);
        assert(ghostty_surface_grid_matches(surface, 80, 24));
        NSMutableData *snapshot = [NSMutableData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        assert(snapshot.length > 0);
        const size_t prefix = ready_length(snapshot);
        if (live) {
            assert(argc == 6);
            ghostty_surface_write_buffer(surface, (const uint8_t *)argv[5], strlen(argv[5]));
            for (int i = 0; i < 400 && !contains(surface, "README.md"); i++) tick(app);
            assert(contains(surface, "README.md"));
        } else {
            assert(ghostty_surface_snapshot_ready(surface, 1, snapshot.bytes, prefix));
        }
        click(surface, drag);
        assert(opened_count == (drag ? 0u : 1u));
        if (!drag) {
            assert(strcmp(opened, argv[2]) == 0);
            assert(opened_kind == (ghostty_action_open_url_kind_e)atoi(argv[3]));
        } else {
            assert(ghostty_surface_has_selection(surface));
        }
        if (!live) {
            // Replace a terminal with an active press/selection and tracked pins.
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GHOSTTY_MODS_SUPER);
            assert(ghostty_surface_snapshot_ready(surface, 2, snapshot.bytes, prefix));
            assert(!ghostty_surface_snapshot_ready(surface, 2, snapshot.bytes, prefix));
            // Overwrite caller-owned storage to expose any borrowed snapshot bytes.
            memset(snapshot.mutableBytes, 0xa5, snapshot.length);
            snapshot = nil;
            click(surface, false);
            if (opened_count != (drag ? 1u : 2u)) fprintf(stderr, "repeat opens=%zu\n", opened_count);
            assert(opened_count == (drag ? 1u : 2u));
            assert(strcmp(opened, argv[2]) == 0);
            assert(opened_kind == (ghostty_action_open_url_kind_e)atoi(argv[3]));
        }
        // Both directions of the host-managed stream must survive the click.
        const char *marker = "\x1b[2J\x1b[Hnative-output";
        ghostty_surface_write_buffer(surface, (const uint8_t *)marker, strlen(marker));
        for (int i = 0; i < 400 && !contains(surface, "native-output"); i++) tick(app);
        assert(contains(surface, "native-output"));
        ghostty_surface_text(surface, "native-input", strlen("native-input"));
        bool received = false;
        for (int i = 0; i < 400; i++) {
            tick(app);
            pthread_mutex_lock(&output_mutex);
            received = output_len == strlen("native-input") && memcmp(output_bytes, "native-input", output_len) == 0;
            pthread_mutex_unlock(&output_mutex);
            if (received) break;
        }
        assert(received);
        ghostty_surface_free(surface);
        ghostty_app_free(app);
        ghostty_config_free(config);
        // The host-owned URL copy must remain valid after native teardown.
        assert(strcmp(opened, argv[2]) == 0);
        fprintf(stdout, "native link click PASS\n");
    }
}
