// Flat-buffer facade over libghostty-vt so Dart FFI reads one uint32 array per frame
// instead of walking iterators cell by cell across the FFI boundary.
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ghostty/vt.h>

#define REPLY_CAP 4096

typedef struct {
  GhosttyTerminal t;
  GhosttyRenderState rs;
  GhosttyRenderStateRowIterator it;
  GhosttyRenderStateRowCells cells;
  GhosttyKeyEncoder keys;
  GhosttyKeyEvent key;
  GhosttyMouseEncoder mouse;
  GhosttyMouseEvent wheel;
  // cached so the SIZE callback never calls back into the terminal mid-write
  uint16_t cols, rows;
  size_t reply_len;
  uint8_t reply[REPLY_CAP];
} Vt;

// A chunk past the buffer is dropped whole: a truncated reply would be a broken sequence.
static void on_write_pty(GhosttyTerminal t, void* ud, const uint8_t* data, size_t len) {
  Vt* v = ud;
  if (len > REPLY_CAP - v->reply_len) return;
  memcpy(v->reply + v->reply_len, data, len);
  v->reply_len += len;
}

// What Ghostty's own surface answers (src/termio/stream_handler.zig, clipboard-write defaults to allow).
static bool on_device_attributes(GhosttyTerminal t, void* ud, GhosttyDeviceAttributes* out) {
  memset(out, 0, sizeof(*out));
  out->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_LEVEL_2;
  out->primary.features[0] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
  out->primary.features[1] = GHOSTTY_DA_FEATURE_CLIPBOARD;
  out->primary.num_features = 2;
  out->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
  out->secondary.firmware_version = 10;
  return true;
}

static bool on_size(GhosttyTerminal t, void* ud, GhosttySizeReportSize* out) {
  Vt* v = ud;
  *out = (GhosttySizeReportSize){ .rows = v->rows, .columns = v->cols, .cell_width = 8, .cell_height = 16 };
  return true;
}

#define CELL_WORDS 5
#define HDR_WORDS 16

Vt* vts_new(uint16_t cols, uint16_t rows, uint32_t scrollback_lines) {
  Vt* v = calloc(1, sizeof(Vt));
  if (ghostty_terminal_new(NULL, &v->t, cols, rows) != GHOSTTY_SUCCESS) { free(v); return NULL; }
  size_t sb = scrollback_lines;
  ghostty_terminal_set(v->t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &sb);
  // Ghostty's own default (grapheme-width-method=unicode): ZWJ/VS16/skin-tone clusters take one wide cell.
  GhosttyTerminalModeConfig gc = { .mode = GHOSTTY_MODE_GRAPHEME_CLUSTER, .value = true };
  ghostty_terminal_set(v->t, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &gc);
  ghostty_render_state_new(NULL, &v->rs);
  // one row below the viewport so the app can scroll by sub-row pixel offsets
  GhosttyRenderStateOverscan os = { .above = 0, .below = 1 };
  ghostty_render_state_set(v->rs, GHOSTTY_RENDER_STATE_OPTION_OVERSCAN, &os);
  ghostty_render_state_row_iterator_new(NULL, &v->it);
  ghostty_render_state_row_cells_new(NULL, &v->cells);
  ghostty_key_encoder_new(NULL, &v->keys);
  ghostty_key_event_new(NULL, &v->key);
  ghostty_mouse_encoder_new(NULL, &v->mouse);
  ghostty_mouse_event_new(NULL, &v->wheel);
  v->cols = cols; v->rows = rows;
  ghostty_terminal_set(v->t, GHOSTTY_TERMINAL_OPT_USERDATA, v);
  ghostty_terminal_set(v->t, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (const void*)on_write_pty);
  ghostty_terminal_set(v->t, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, (const void*)on_device_attributes);
  ghostty_terminal_set(v->t, GHOSTTY_TERMINAL_OPT_SIZE, (const void*)on_size);
  return v;
}

void vts_free(Vt* v) {
  if (!v) return;
  ghostty_mouse_event_free(v->wheel);
  ghostty_mouse_encoder_free(v->mouse);
  ghostty_key_event_free(v->key);
  ghostty_key_encoder_free(v->keys);
  ghostty_render_state_row_cells_free(v->cells);
  ghostty_render_state_row_iterator_free(v->it);
  ghostty_render_state_free(v->rs);
  ghostty_terminal_free(v->t);
  free(v);
}

void vts_write(Vt* v, const uint8_t* data, size_t len) { ghostty_terminal_vt_write(v->t, data, len); }

void vts_resize(Vt* v, uint16_t cols, uint16_t rows) {
  v->cols = cols; v->rows = rows;
  ghostty_terminal_resize(v->t, cols, rows, 8, 16);
}

// Full reset (RIS): RESYNC starts the emulator over before the GRID replay, and drops replies to the old stream.
void vts_reset(Vt* v) {
  ghostty_terminal_reset(v->t);
  v->reply_len = 0;
}

// DEC private mode value (e.g. 2026 synchronized output, 1049 alternate screen): 1 set, 0 reset, -1 unknown.
int32_t vts_mode(Vt* v, uint16_t mode) {
  GhosttyTerminalModeConfig m = { .mode = ghostty_mode_new(mode, false), .value = false };
  if (ghostty_terminal_get(v->t, GHOSTTY_TERMINAL_DATA_MODE, &m) != GHOSTTY_SUCCESS) return -1;
  return m.value ? 1 : 0;
}

// row < 0 snaps to the bottom (live area).
void vts_scroll_to(Vt* v, int64_t row) {
  GhosttyTerminalScrollViewport s = {0};
  if (row < 0) {
    s.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
  } else {
    s.tag = GHOSTTY_SCROLL_VIEWPORT_ROW;
    s.value.row = (size_t)row;
  }
  ghostty_terminal_scroll_viewport(v->t, s);
}

static uint32_t rgb(GhosttyColorRgb c) { return 0xFF000000u | (c.r << 16) | (c.g << 8) | c.b; }

// Header: cols, rows, cursor_x, cursor_y, cursor_flags(visible|has<<1|style<<4), default fg, default bg,
// scrollbar total, offset, len, active screen, extras word count, grid rows (rows + overscan below). Cells: cp, extras offset, fg, bg, flags.
// A multi-codepoint cluster (2..16 codepoints) stores its codepoints after the cell grid; the cell holds their
// word offset in w[1], and w[1] == 0 means "no cluster". A longer cluster keeps only its base codepoint (glen 1).
// fg/bg alpha 0 = default color. flags: bold 1, italic 2, underline 4, inverse 8, faint 16, strike 32,
// invisible 64, wide 1<<8, spacer 1<<9, grapheme len << 16.
// Returns words written, or -needed when cap is too small (grid plus every cluster), or 0 on failure.
int32_t vts_snapshot(Vt* v, uint32_t* out, int32_t cap) {
  GhosttyTerminalScrollbar sbar = {0};
  ghostty_terminal_get(v->t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sbar);
  uint32_t screen = 0;
  ghostty_terminal_get(v->t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
  if (ghostty_render_state_update(v->rs, v->t) != GHOSTTY_SUCCESS) return 0;

  uint16_t cols = 0, rows = 0;
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
  GhosttyRenderStateOverscan cap_os = {0};
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_OVERSCAN, &cap_os);
  uint16_t grid_rows = rows + cap_os.below;
  int64_t need = HDR_WORDS + (int64_t)cols * grid_rows * CELL_WORDS;
  // first pass: size the clusters, so a short buffer gets the full size back instead of dropped clusters
  int64_t total = need;
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &v->it);
  for (int r = 0; r < grid_rows && ghostty_render_state_row_iterator_next(v->it); r++) {
    ghostty_render_state_row_get(v->it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &v->cells);
    for (int c = 0; c < cols && ghostty_render_state_row_cells_next(v->cells); c++) {
      uint32_t glen = 0;
      ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
      if (glen > 1 && glen <= 16) total += glen;
    }
  }
  if (total > INT32_MAX) return 0;
  if (cap < total) return -(int32_t)total;

  GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
  GhosttyRenderStateCursor cur = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cur);

  for (int i = 0; i < HDR_WORDS; i++) out[i] = 0;
  out[0] = cols; out[1] = rows;
  out[2] = cur.viewport_x; out[3] = cur.viewport_y;
  out[4] = (cur.visible ? 1 : 0) | (cur.viewport_has_value ? 2 : 0) | ((uint32_t)cur.visual_style << 4);
  out[5] = rgb(colors.foreground); out[6] = rgb(colors.background);
  out[7] = (uint32_t)sbar.total; out[8] = (uint32_t)sbar.offset; out[9] = (uint32_t)sbar.len;
  out[10] = screen;
  out[12] = grid_rows;

  ghostty_render_state_get(v->rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &v->it);
  uint32_t* p = out + HDR_WORDS;
  int32_t extras = (int32_t)need;
  int r = 0;
  while (ghostty_render_state_row_iterator_next(v->it) && r < grid_rows) {
    ghostty_render_state_row_get(v->it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &v->cells);
    int c = 0;
    while (ghostty_render_state_row_cells_next(v->cells) && c < cols) {
      uint32_t* w = p + (r * cols + c) * CELL_WORDS;
      w[0] = w[1] = w[2] = w[3] = w[4] = 0;
      uint32_t glen = 0;
      ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
      GhosttyCell raw = 0;
      bool has_raw = ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS;
      if (glen > 16) {
        // dropped cluster: base codepoint only, so no reader takes it for a stored cluster
        glen = 1;
        if (has_raw) ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &w[0]);
      } else if (glen > 0) {
        uint32_t cps[16] = {0};
        ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, cps);
        w[0] = cps[0];
        if (glen > 1) {  // room is guaranteed by the first pass
          w[1] = (uint32_t)extras;
          for (uint32_t i = 0; i < glen; i++) out[extras++] = cps[i];
        }
      }
      GhosttyColorRgb col;
      if (ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &col) == GHOSTTY_SUCCESS) w[2] = rgb(col);
      if (ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &col) == GHOSTTY_SUCCESS) w[3] = rgb(col);
      uint32_t f = glen << 16;
      GhosttyStyle st = GHOSTTY_INIT_SIZED(GhosttyStyle);
      if (ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &st) == GHOSTTY_SUCCESS) {
        f |= (st.bold ? 1 : 0) | (st.italic ? 2 : 0) | (st.underline ? 4 : 0) | (st.inverse ? 8 : 0) |
             (st.faint ? 16 : 0) | (st.strikethrough ? 32 : 0) | (st.invisible ? 64 : 0);
      }
      if (has_raw) {
        GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
        if (wide == GHOSTTY_CELL_WIDE_WIDE) f |= 1u << 8;
        if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) f |= 1u << 9;
      }
      w[4] = f;
      c++;
    }
    r++;
  }
  ghostty_render_state_clean(v->rs);
  out[11] = (uint32_t)(extras - (int32_t)need);
  return extras;
}

// Encoders return bytes written, 0 for nothing to send, or -needed when cap is short.
static int32_t encoded(GhosttyResult r, size_t n) {
  if (r == GHOSTTY_OUT_OF_SPACE) return -(int32_t)n;
  return r == GHOSTTY_SUCCESS ? (int32_t)n : 0;
}

// mods: shift 1, ctrl 2, alt 4 (GhosttyMods). unshifted: the key's unshifted codepoint, 0 for none.
int32_t vts_encode_key(Vt* v, uint32_t key, uint32_t mods, uint32_t unshifted, const char* utf8, size_t utf8_len,
                       uint8_t* out, int32_t cap) {
  ghostty_key_encoder_setopt_from_terminal(v->keys, v->t);
  // the host test dylib is macOS, where alt would otherwise be Option and type text; Android ignores it
  GhosttyOptionAsAlt option_as_alt = GHOSTTY_OPTION_AS_ALT_TRUE;
  ghostty_key_encoder_setopt(v->keys, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &option_as_alt);
  ghostty_key_event_set_action(v->key, GHOSTTY_KEY_ACTION_PRESS);
  ghostty_key_event_set_key(v->key, (GhosttyKey)key);
  ghostty_key_event_set_mods(v->key, (GhosttyMods)mods);
  ghostty_key_event_set_consumed_mods(v->key, 0);
  ghostty_key_event_set_composing(v->key, false);
  ghostty_key_event_set_utf8(v->key, utf8, utf8_len);
  ghostty_key_event_set_unshifted_codepoint(v->key, unshifted);
  size_t n = 0;
  return encoded(ghostty_key_encoder_encode(v->keys, v->key, (char*)out, (size_t)cap, &n), n);
}

// data is rewritten in place (unsafe control bytes become spaces).
int32_t vts_encode_paste(Vt* v, char* data, size_t len, uint8_t* out, int32_t cap) {
  size_t n = 0;
  return encoded(ghostty_paste_encode(data, len, vts_mode(v, 2004) == 1, (char*)out, (size_t)cap, &n), n);
}

// One mouse event at pixel (x, y) of the 8x16 cells on_size reports, so an SGR-pixels (1016) program maps it back.
static int32_t encode_mouse(Vt* v, GhosttyMouseAction action, GhosttyMouseButton button, float x, float y,
                            uint8_t* out, int32_t cap) {
  ghostty_mouse_encoder_setopt_from_terminal(v->mouse, v->t);
  GhosttyMouseEncoderSize sz = { .size = sizeof(sz), .screen_width = v->cols * 8u, .screen_height = v->rows * 16u,
                                 .cell_width = 8, .cell_height = 16 };
  ghostty_mouse_encoder_setopt(v->mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &sz);
  ghostty_mouse_event_set_action(v->wheel, action);
  ghostty_mouse_event_set_button(v->wheel, button);
  ghostty_mouse_event_set_mods(v->wheel, 0);
  ghostty_mouse_event_set_position(v->wheel, (GhosttyMousePosition){ .x = x, .y = y });
  size_t n = 0;
  return encoded(ghostty_mouse_encoder_encode(v->mouse, v->wheel, (char*)out, (size_t)cap, &n), n);
}

int32_t vts_encode_wheel(Vt* v, int32_t up, uint16_t col, uint16_t row, uint8_t* out, int32_t cap) {
  return encode_mouse(v, GHOSTTY_MOUSE_ACTION_PRESS, up ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE,
                      col * 8.0f, row * 16.0f, out, cap);
}

// Left press then release at the cell's centre; 0 when the program does not track the mouse.
int32_t vts_encode_click(Vt* v, uint16_t col, uint16_t row, uint8_t* out, int32_t cap) {
  float x = col * 8.0f + 4, y = row * 16.0f + 8;
  int32_t a = encode_mouse(v, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, x, y, out, cap);
  if (a <= 0) return a == 0 ? 0 : 2 * a; // press and release are the same length
  int32_t b = encode_mouse(v, GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT, x, y, out + a, cap - a);
  return b < 0 ? -(a - b) : a + b;
}

int32_t vts_encode_focus(Vt* v, int32_t gained, uint8_t* out, int32_t cap) {
  if (vts_mode(v, 1004) != 1) return 0;
  size_t n = 0;
  return encoded(ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, (char*)out, (size_t)cap, &n), n);
}

// Drains the replies (DA, CPR, size reports...) WRITE_PTY collected during vts_write.
int32_t vts_take_replies(Vt* v, uint8_t* out, int32_t cap) {
  int32_t n = (int32_t)v->reply_len;
  if (cap < n) return -n;
  memcpy(out, v->reply, v->reply_len);
  v->reply_len = 0;
  return n;
}
