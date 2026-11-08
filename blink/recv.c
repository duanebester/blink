// recv(sock, max, ms, prefix): one read of up to max bytes, put after
// prefix (the framer's leftover bytes) in one flat Array<U32>, a byte a
// slot, with the count. ms > 0 bounds the wait: past it, Wait{prefix}
// hands the leftover back. EOF is Done{None}. It builds the array with the
// runtime's block helpers (BLK_ALLOC, blk_write, term_blk), which are not
// a public API: re-check this file when Bend changes.

// The bytes as an array of 2^d slots, zero past n, and n.
static Term blink_recv_array(Env e, const char* p, u64 n) {
  u32 d = 0;
  while ((1ull << d) < n) {
    d += 1;
  }
  BLK_ALLOC(l, blk_wcls(false, d))
  for (u64 i = 0; i < (1ull << d); i += 1) {
    blk_write(e.mem, false, l, (u32)i, i < n ? (uint8_t)p[i] : 0);
  }
  return io_tup(e, term_blk(false, d, l), (Term)n);
}

static Term blink_recv_more(Env e, IoWork* w) {
  int fd   = (int)w->hand;
  u64 have = (u64)w->item;
  ssize_t n;
  do {
    n = recv(fd, w->data + have, (size_t)w->made, 0);
  } while (n < 0 && errno == EINTR);
  w->size = io_sys_end(w, n);
  if (io_again(w)) {
    return io_wait_on(w, fd, POLLIN, w->time, blink_recv_more);
  }
  Term r;
  if (w->code == EAGAIN) {
    r = io_box(e, CID(Wait), io_list(e, w->data, have));
  } else if (w->code != 0) {
    r = io_box(e, CID(Ready), io_fail(e, w->code, NULL));
  } else if (w->size == 0) {
    r = io_box(e, CID(Ready), io_done(e, term_pak(CID(None), 0)));
  } else {
    r = io_box(e, CID(Ready), io_done(e, io_box(e, CID(Some),
      blink_recv_array(e, w->data, have + w->size))));
  }
  free(w->data);
  return io_tup(e, io_hand(w->hand), r);
}

Term blink_recv_run(Env e, Term* f, IoWork* w) {
  u64   have = 0;
  char* pre  = io_cbuf(e, f[3], &have, CID(Con));
  w->hand = (intptr_t)io_hand_v(f[0]);
  w->time = f[2] ? io_until(f[2]) : 0;
  w->code = 0;
  if (f[1] == 0 || pre == NULL) {
    free(pre);
    return io_tup(e, io_hand(w->hand), io_box(e, CID(Ready), io_fail(e, EINVAL, NULL)));
  }
  w->made = f[1] < INT32_MAX ? (intptr_t)f[1] : INT32_MAX;
  w->data = io_mem(malloc(have + (u64)w->made));
  memcpy(w->data, pre, have);
  free(pre);
  w->item = (Term)have;
  return blink_recv_more(e, w);
}

static void __attribute__((constructor)) blink_recv_use(void) {
  io_eff(CID(recv), blink_recv_run);
}
