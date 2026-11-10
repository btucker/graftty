#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

// Generate through the producer's public VT API, preserving raw OSC 7 values.
int main(int argc, char **argv) {
    assert(argc == 3);
    GhosttyTerminal terminal = NULL;
    assert(ghostty_terminal_new(NULL, &terminal, 80, 24) == GHOSTTY_SUCCESS);
    ghostty_terminal_vt_write(terminal, (const uint8_t *)argv[2], strlen(argv[2]));
    uint8_t *bytes;
    size_t len;
    assert(ghostty_snapshot_encode_alloc(terminal, NULL, &bytes, &len) == GHOSTTY_SUCCESS);
    FILE *file = fopen(argv[1], "wb");
    assert(file);
    assert(fwrite(bytes, 1, len, file) == len);
    assert(fclose(file) == 0);
    ghostty_free(NULL, bytes, len);
    ghostty_terminal_free(terminal);
}
