# Prototype: Blink on a Base byte value (bendlang/bend#1573)

Not for main. `bend-1573.patch` adds to Bend 2.0.40's Base a byte value,
`Bytes{len, buf: Array<U32>}`, and `TCP.recv_buf` / `TCP.try_recv_buf`,
which fill it straight from the read. Blink then frames whole messages
out of the buffer (723efe1's framer), joining the bytes left from the last
read in Bend. Blink itself still has no foreign code, and
`bend --verdict` passes on a program that runs it.

    cp -r ~/.bend ~/.bend-proto
    (cd ~/.bend-proto && patch -p1 < .../proto/bend-1573.patch)
    PATH=~/.bend-proto/bin:$PATH bend build/count.bend -o build/count

The framer laws in LAWS.bend are main's and don't hold here; the replay
test and tests/aggregates.bend pass.
