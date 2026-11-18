// Flat-buffer facade over libghostty-vt so Dart FFI reads one uint32 array per frame
// instead of walking iterators cell by cell across the FFI boundary.
#include <stdint.h>
#include <stdlib.h>
#include <ghostty/vt.h>

typedef struct {
  GhosttyTerminal t;
  GhosttyRenderState rs;
  GhosttyRenderStateRowIterator it;
  GhosttyRenderStateRowCells cells;
} Vt;

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
  return v;
}

void vts_free(Vt* v) {
  if (!v) return;
  ghostty_render_state_row_cells_free(v->cells);
  ghostty_render_state_row_iterator_free(v->it);
  ghostty_render_state_free(v->rs);
  ghostty_terminal_free(v->t);
  free(v);
}

void vts_write(Vt* v, const uint8_t* data, size_t len) { ghostty_terminal_vt_write(v->t, data, len); }

void vts_resize(Vt* v, uint16_t cols, uint16_t rows) { ghostty_terminal_resize(v->t, cols, rows, 8, 16); }

// Full reset (RIS): RESYNC starts the emulator over before the GRID replay.
void vts_reset(Vt* v) { ghostty_terminal_reset(v->t); }

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
// A multi-codepoint cluster stores its codepoints after the cell grid; the cell holds their word offset.
// fg/bg alpha 0 = default color. flags: bold 1, italic 2, underline 4, inverse 8, faint 16, strike 32,
// invisible 64, wide 1<<8, spacer 1<<9, grapheme len << 16.
// Returns words written, or -needed when cap is too small.
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
  int32_t need = HDR_WORDS + cols * grid_rows * CELL_WORDS;
  if (cap < need) return -need;

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
  int32_t extras = need;
  int r = 0;
  while (ghostty_render_state_row_iterator_next(v->it) && r < grid_rows) {
    ghostty_render_state_row_get(v->it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &v->cells);
    int c = 0;
    while (ghostty_render_state_row_cells_next(v->cells) && c < cols) {
      uint32_t* w = p + (r * cols + c) * CELL_WORDS;
      w[0] = w[1] = w[2] = w[3] = w[4] = 0;
      uint32_t glen = 0;
      ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &glen);
      if (glen > 0) {
        uint32_t cps[16] = {0};
        if (glen <= 16) ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, cps);
        w[0] = cps[0];
        if (glen > 1 && glen <= 16 && extras + (int32_t)glen <= cap) {
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
      GhosttyCell raw = 0;
      if (ghostty_render_state_row_cells_get(v->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS) {
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
  out[11] = (uint32_t)(extras - need);
  return extras;
}
