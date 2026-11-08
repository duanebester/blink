// recv(sock, max, ms, prefix): recv.c's twin for the JS lane. An
// Array<U32> is a JS array of 2^d numbers here.

function blink_recv_array(pre, b, n) {
  const total = pre.length + n;
  let size = 1;
  while (size < total) {
    size *= 2;
  }
  const a = new Array(size).fill(0);
  for (let i = 0; i < pre.length; i++) {
    a[i] = pre[i];
  }
  for (let i = 0; i < n; i++) {
    a[pre.length + i] = b[i];
  }
  return io_tup(a, total);
}

function blink_recv(socket, max, ms, prefix, k) {
  const pre = io_unlist(prefix);
  const at = Number(ms) > 0 ? io_until(ms) : undefined;
  const ready = (r) => io_tup(socket, { $: CID(Ready), value: r });
  if (Number(max) === 0) {
    return ready(io_fail(22));
  }
  const sys = io_sys();
  const len = Math.min(Number(max), 2147483647);
  const b = new Uint8Array(len);
  const again = sys.mac ? 35 : 11;
  const intr = 4;
  const go = () => {
    let n = Number(sys.recv(socket, sys.ptr(b), len, 0));
    while (n < 0 && sys.errno() === intr) {
      n = Number(sys.recv(socket, sys.ptr(b), len, 0));
    }
    if (n < 0) {
      const code = sys.errno();
      if (code !== again) {
        return ready(io_fail(code));
      }
      if (io_late(at)) {
        return io_tup(socket, { $: CID(Wait), rest: io_list(pre, pre.length) });
      }
      io_park_on(socket, false, k, go, at);
      return undefined;
    }
    return ready(io_done(n === 0 ? { $: CID(None) }
      : { $: CID(Some), value: blink_recv_array(pre, b, n) }));
  };
  return go();
}

io_eff(CID(recv), blink_recv);
