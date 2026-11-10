#include <stdint.h>
// Dependency experiment, not an implementation of the pending TERM-12 specs.
// Run against the patched source from scripts/deps checkout ghostty.
#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define OK(call) do { \
  GhosttyResult result_ = (call); \
  if (result_ != GHOSTTY_SUCCESS) { \
    fprintf(stderr, "%s:%d: %s returned %d\n", __FILE__, __LINE__, #call, result_); \
    abort(); \
  } \
} while (0)

typedef struct { uint8_t *bytes; size_t len; } Bytes;
typedef struct { GhosttySnapshotDecoder decoder; GhosttyTerminal terminal; } Import;

static double milliseconds(void) {
  struct timespec t;
  assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}

static void write_text(GhosttyTerminal terminal, const char *text) {
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));
}

static void write_rows(GhosttyTerminal terminal, size_t first, size_t count) {
  for (size_t i = first; i < first + count; i++) {
    char line[32];
    snprintf(line, sizeof(line), "row-%06zu\r\n", i);
    write_text(terminal, line);
  }
}

static Bytes format(GhosttyTerminal terminal, const GhosttySelection *selection) {
  GhosttyFormatter formatter = NULL;
  OK(ghostty_formatter_terminal_new(NULL, &formatter, terminal));
  GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  bool unwrap = true, trim = true;
  OK(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit));
  OK(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap));
  OK(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim));
  OK(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, selection));
  Bytes text = {0};
  OK(ghostty_formatter_format_alloc(formatter, NULL, &text.bytes, &text.len));
  ghostty_formatter_free(formatter);
  return text;
}

static void free_bytes(Bytes bytes) { ghostty_free(NULL, bytes.bytes, bytes.len); }

static void equal_bytes(Bytes a, Bytes b) {
  assert(a.len == b.len);
  assert(memcmp(a.bytes, b.bytes, a.len) == 0);
}

static GhosttySelection viewport_row(GhosttyTerminal terminal) {
  GhosttySelection selection = {0};
  GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT};
  OK(ghostty_terminal_grid_ref(terminal, point, &selection.start));
  point.value.coordinate.x = 9;
  OK(ghostty_terminal_grid_ref(terminal, point, &selection.end));
  return selection;
}

static Bytes selected_text(GhosttyTerminal terminal) {
  GhosttySelection selection = {0};
  OK(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection));
  return format(terminal, &selection);
}

static GhosttyTerminalScrollbar scrollbar(GhosttyTerminal terminal) {
  GhosttyTerminalScrollbar bar;
  OK(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar));
  return bar;
}

static Import restore(Bytes snapshot) {
  Import imported = {0};
  OK(ghostty_snapshot_decoder_new_buf(NULL, &imported.decoder, snapshot.bytes, snapshot.len));
  OK(ghostty_snapshot_decoder_ready(imported.decoder, &imported.terminal));
  return imported;
}

static void close_import(Import imported) {
  ghostty_snapshot_decoder_free(imported.decoder);
  ghostty_terminal_free(imported.terminal);
}

static void assert_rows(GhosttyTerminal terminal, size_t first, size_t count) {
  Bytes text = format(terminal, NULL);
  size_t offset = 0;
  for (size_t i = first; i < first + count; i++) {
    char line[32];
    int len = snprintf(line, sizeof(line), "row-%06zu", i);
    assert(len > 0 && (size_t)len < sizeof(line));
    if (offset + (size_t)len > text.len || memcmp(text.bytes + offset, line, len)) {
      fprintf(stderr, "missing, duplicated, or reordered row %zu at byte %zu\n", i, offset);
      abort();
    }
    offset += len;
    if (offset < text.len) assert(text.bytes[offset++] == '\n');
  }
  // A trailing empty active row is allowed; additional content is not.
  while (offset < text.len) assert(text.bytes[offset++] == '\n');
  free_bytes(text);
}

static void exercise_paging(Bytes snapshot, size_t rows) {
  double start = milliseconds();
  Import imported = restore(snapshot);
  double ready_ms = milliseconds() - start;
  size_t ready_bytes = 0;
  OK(ghostty_snapshot_decoder_get(imported.decoder,
      GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &ready_bytes));
  assert(ready_bytes < snapshot.len);
  assert(scrollbar(imported.terminal).total < rows);

  // No history is consumed while the parser continuation and live rows arrive.
  write_text(imported.terminal, "m");
  write_rows(imported.terminal, rows, 100);
  GhosttyRenderState render = NULL;
  OK(ghostty_render_state_new(NULL, &render));
  OK(ghostty_render_state_update(render, imported.terminal));
  size_t unchanged_offset = 0;
  OK(ghostty_snapshot_decoder_get(imported.decoder,
      GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &unchanged_offset));
  assert(unchanged_offset == ready_bytes);

  // Import once while following the live bottom, then read and select history.
  OK(ghostty_snapshot_decoder_next(imported.decoder));
  size_t first_page_rows = 0;
  OK(ghostty_snapshot_decoder_get(imported.decoder,
      GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS, &first_page_rows));
  assert(first_page_rows > 0);
  bool follows_live = false;
  OK(ghostty_terminal_get(imported.terminal,
      GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &follows_live));
  assert(follows_live);
  ghostty_terminal_scroll_viewport(imported.terminal,
      (GhosttyTerminalScrollViewport){.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW, .value.row = 0});
  GhosttySelection selection = viewport_row(imported.terminal);
  OK(ghostty_terminal_set(imported.terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection));
  Bytes anchor = format(imported.terminal, &selection);
  assert(anchor.len == 10);

  // Output continues while the reader is in history and more pages are pending.
  write_rows(imported.terminal, rows + 100, 100);

  size_t pages = 1, dropped = 0;
  GhosttyResult result;
  while ((result = ghostty_snapshot_decoder_next(imported.decoder)) == GHOSTTY_SUCCESS) {
    size_t applied = 0;
    OK(ghostty_snapshot_decoder_get(imported.decoder,
        GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS, &applied));
    if (applied == 0) dropped++;
    pages++;
    OK(ghostty_render_state_update(render, imported.terminal));
  }
  assert(result == GHOSTTY_NO_VALUE && dropped == 0);
  Bytes selected = selected_text(imported.terminal);
  equal_bytes(anchor, selected);
  free_bytes(selected);
  selection = viewport_row(imported.terminal);
  Bytes visible = format(imported.terminal, &selection);
  equal_bytes(anchor, visible);
  free_bytes(visible);
  free_bytes(anchor);
  assert_rows(imported.terminal, 0, rows + 200);
  printf("rows=%zu snapshot_bytes=%zu ready_bytes=%zu ready_ms=%.3f pages=%zu order/selection/anchor=PASS\n",
      rows, snapshot.len, ready_bytes, ready_ms, pages);
  ghostty_render_state_free(render);
  close_import(imported);
}

static void exercise_resize(Bytes snapshot) {
  Import imported = restore(snapshot);
  OK(ghostty_terminal_resize(imported.terminal, 40, 24, 8, 16));
  size_t before = scrollbar(imported.terminal).total;
  size_t discarded = 0;
  GhosttyResult result;
  while ((result = ghostty_snapshot_decoder_next(imported.decoder)) == GHOSTTY_SUCCESS) {
    size_t applied = 1;
    OK(ghostty_snapshot_decoder_get(imported.decoder,
        GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS, &applied));
    assert(applied == 0);
    discarded++;
  }
  assert(result == GHOSTTY_NO_VALUE && discarded > 0);
  assert(scrollbar(imported.terminal).total == before);
  write_text(imported.terminal, "mstill-live\r\n");
  GhosttyRenderState render = NULL;
  OK(ghostty_render_state_new(NULL, &render));
  OK(ghostty_render_state_update(render, imported.terminal));
  ghostty_render_state_free(render);
  printf("resize: %zu pages discarded despite successful decode; recovery REQUIRED\n", discarded);
  close_import(imported);
}

static void exercise_alternate(Bytes snapshot, size_t rows) {
  Import imported = restore(snapshot);
  write_text(imported.terminal, "m\x1b[?1049halt-screen");
  GhosttyResult result;
  while ((result = ghostty_snapshot_decoder_next(imported.decoder)) == GHOSTTY_SUCCESS) {}
  assert(result == GHOSTTY_NO_VALUE);
  write_text(imported.terminal, "\x1b[?1049l");
  assert_rows(imported.terminal, 0, rows);
  puts("alternate screen: primary history order=PASS");
  close_import(imported);
}

int main(void) {
  const size_t sizes[] = {1000, 10000, 100000};
  for (size_t n = 0; n < sizeof(sizes) / sizeof(sizes[0]); n++) {
    GhosttyTerminal source = NULL;
    OK(ghostty_terminal_new(NULL, &source, 80, 24));
    size_t continuation_limit = 1024;
    OK(ghostty_terminal_set(source, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation_limit));
    // NULL restores the bounded default; SIZE_MAX removes the limit.
    size_t unlimited_scrollback = SIZE_MAX;
    OK(ghostty_terminal_set(source, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unlimited_scrollback));
    OK(ghostty_terminal_set(source, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &unlimited_scrollback));
    write_rows(source, 0, sizes[n]);
    write_text(source, "\x1b[31");
    Bytes snapshot = {0};
    double start = milliseconds();
    OK(ghostty_snapshot_encode_alloc(source, NULL, &snapshot.bytes, &snapshot.len));
    printf("rows=%zu full_encode_ms=%.3f\n", sizes[n], milliseconds() - start);
    exercise_paging(snapshot, sizes[n]);
    exercise_resize(snapshot);
    exercise_alternate(snapshot, sizes[n]);
    free_bytes(snapshot);
    ghostty_terminal_free(source);
  }
  return 0;
}
