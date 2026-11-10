#include <stdint.h>
#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    assert(argc == 2 || (argc == 3 && strcmp(argv[2], "--modes") == 0));
    GhosttyTerminal terminal = NULL;
    assert(ghostty_terminal_new(NULL, &terminal, 80, 24) == GHOSTTY_SUCCESS);
    size_t limit = 1024;
    assert(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &limit) == GHOSTTY_SUCCESS);
    // NULL restores the bounded default; SIZE_MAX removes the limit.
    size_t unlimited_scrollback = SIZE_MAX;
    assert(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unlimited_scrollback) == GHOSTTY_SUCCESS);
    assert(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &unlimited_scrollback) == GHOSTTY_SUCCESS);
    for (int i = 0; i < 100000; i++) {
        char line[32];
        snprintf(line, sizeof(line), "row-%06d\r\n", i);
        ghostty_terminal_vt_write(terminal, (const uint8_t *)line, strlen(line));
    }
    if (argc == 3) {
        const char *modes = "\x1b[20h\x1b[?2026h";
        ghostty_terminal_vt_write(terminal, (const uint8_t *)modes, strlen(modes));
    }
    ghostty_terminal_vt_write(terminal, (const uint8_t *)"\x1b[31", 4);
    uint8_t *snapshot;
    size_t len;
    assert(ghostty_snapshot_encode_alloc(terminal, NULL, &snapshot, &len) == GHOSTTY_SUCCESS);
    FILE *file = fopen(argv[1], "wb");
    assert(file);
    assert(fwrite(snapshot, 1, len, file) == len);
    assert(fclose(file) == 0);
    ghostty_free(NULL, snapshot, len);
    ghostty_terminal_free(terminal);
    return 0;
}
