"""Benchmark cases: a kernel, its inputs, the launch and a NumPy check.

A case's `run(dev)` writes the inputs into a cleared device, launches once, checks the outputs against NumPy (raises
AssertionError on a mismatch) and returns (LaunchResult, outputs as uint32) so the runner can also require every
backend to be bit-identical to the golden model.

Groups: `micro` cases isolate one machine property each (peak issue rate, bandwidth at each memory level, coalescing,
latency, bank conflicts, atomics, divergence, barriers); `app` cases are small real kernels.
"""
import os, sys, threading

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
from mahi import assemble, assemble_file, Buffer  # noqa: E402
from mahi.nn import kernel as nn_kernel, FusedMLP, init_weights  # noqa: E402

KDIR = os.path.join(HERE, 'kernels')
_k = {}


def K(name):
    if name not in _k: _k[name] = assemble_file(os.path.join(KDIR, name + '.s'))
    return _k[name]


class Case:
    def __init__(self, name, group, desc, run, threads, mem_words=1024, block=None, shared=0, elements=None):
        self.name, self.group, self.desc, self._run = name, group, desc, run
        self.threads, self.mem_words, self.block, self.shared = threads, mem_words, block, shared
        self.elements = elements

    def supported(self, profile):
        """None, or why this case cannot run on the profile"""
        if self.block and profile.block != self.block: return f'needs block size {self.block}'
        if self.shared > profile.shared: return f'needs {self.shared} words of shared memory'
        if self.threads % min(profile.block, self.threads): return 'thread count not a multiple of the block'
        return None

    def run(self, dev, soft=False):
        """-> (LaunchResult, outputs). soft=True: a failed NumPy check does not raise; the messages are returned as
        a third element (the runner keeps the metrics of a wrong result and reports the failure)"""
        dev.free_all(); dev.mem[:] = [0] * len(dev.mem)
        _tl.soft = [] if soft else None
        try:
            r, out = self._run(dev)
        finally:
            failures, _tl.soft = _tl.soft, None
        return (r, out, failures) if soft else (r, out)


CASES = []
_tl = threading.local()


def _check(fn, *a, **kw):
    try:
        fn(*a, **kw)
    except AssertionError as e:
        if getattr(_tl, 'soft', None) is None: raise
        _tl.soft.append(str(e).strip().splitlines()[0][:300])


def case(*a, **kw):
    c = Case(*a, **kw); CASES.append(c); return c


def buf(dev, n, name=None):
    """line-aligned allocation (4-word lines), so coalescing is not blurred by misalignment"""
    dev.heap = (dev.heap + 3) & ~3
    return dev.alloc(n, name)


def u32(*arrays): return np.concatenate([np.asarray(a).ravel().view(np.uint32) for a in arrays])


def close(got, want, rtol=1e-4, atol=1e-5, what=''):
    def f():
        g, w = np.asarray(got, np.float64), np.asarray(want, np.float64)
        bad = ~np.isclose(g, w, rtol=rtol, atol=atol)
        assert not bad.any(), f'{what}: {bad.sum()} of {bad.size} values off, worst {np.abs(g - w).max():.3g}'
    _check(f)


def exact(got, want, what=''):
    def f():
        g, w = np.asarray(got), np.asarray(want)
        bad = g != w
        assert not bad.any(), f'{what}: {bad.sum()} of {bad.size} values wrong, first got {g[bad][:4]} want {w[bad][:4]}'
    _check(f)


# ================================================================================================= micro: compute
def gen_chain(op, chains, unroll):
    """`chains` independent accumulators, `unroll` rounds per loop trip. FMA: r += 0.5 * 0.25 (exact in FP32);
    ADD: r += 1; DIV: r = r / 1. out[c*T + gid] = accumulator c (coalesced)."""
    init = {'FMA': 'LIF   r{r}, 1.0', 'ADD': 'CONST r{r}, 1', 'DIV': 'LI    r{r}, 1000'}[op]
    body = {'FMA': 'FMA   r{r}, r3, r4', 'ADD': 'ADD   r{r}, r{r}, r1', 'DIV': 'DIV   r{r}, r{r}, r1'}[op]
    L = ['.param out, iters, T', 'CONST r0, 0', 'CONST r1, 1', 'MUL r2, bid, nthr', 'ADD r2, r2, tid',
         'LIF r3, 0.5', 'LIF r4, 0.25']
    L += [init.format(r=5 + c) for c in range(chains)]
    L += ['LDR r20, r0, iters', 'loop: CMP r20, r0', 'BRz fin']
    L += [body.format(r=5 + c) for _ in range(unroll) for c in range(chains)]
    L += ['SUB r20, r20, r1', 'JMP loop', 'fin: LDR r21, r0, out', 'ADD r21, r21, r2', 'LDR r22, r0, T']
    L += [f'STR r{5 + c}, [r21]\nADD r21, r21, r22' for c in range(chains)]
    L += ['EXIT']
    return assemble('\n'.join(L), name=f'{op.lower()}_chain{chains}x{unroll}')


def chain_case(op, chains, unroll=4, iters=64, threads=32):
    prog = gen_chain(op, chains, unroll)
    want = {'FMA': np.float32(1.0 + iters * unroll * 0.125), 'ADD': np.uint32(1 + iters * unroll),
            'DIV': np.uint32(1000)}[op]

    def run(dev):
        out = buf(dev, threads * chains)
        r = dev.launch(prog, threads=threads, out=out, iters=iters, T=threads)
        got = dev.read(out, np.float32 if op == 'FMA' else np.uint32)
        exact(got, np.full(threads * chains, want), f'{op} chains')
        return r, u32(got)
    what = {'FMA': 'FP32 FMA', 'ADD': 'integer ADD', 'DIV': 'integer DIV'}[op]
    return case(f'{op.lower()}_chain{chains}', 'micro', f'{chains} independent {what} chain(s) per thread, unroll {unroll}',
                run, threads, elements=threads * chains * unroll * iters)


for c in (1, 2, 4, 8): chain_case('FMA', c)
for c in (1, 4): chain_case('ADD', c)
for c in (1, 4): chain_case('DIV', c, unroll=1, iters=8)


# ================================================================================================== micro: memory
def stream_read(tag, n, reps, threads=32):
    mem = max(1024, 1 << (n + 256).bit_length())

    def run(dev):
        rng = np.random.default_rng(1)
        a = buf(dev, n); out = buf(dev, threads)
        x = rng.integers(-8, 8, n).astype(np.float32)          # small integers: every partial sum is exact
        dev.write(a, x)
        r = dev.launch(K('stream_read'), threads=threads, a=a, out=out, n=n, T=threads, reps=reps)
        got = dev.read(out)
        exact(got, reps * x.reshape(-1, threads).sum(0), 'stream_read')
        return r, u32(got)
    return case(f'stream_read_{tag}', 'micro', f'read {n} words x {reps} passes (footprint {tag.upper()})', run,
                threads, mem_words=mem, elements=n * reps)


stream_read('l1', 64, 16)
stream_read('l2', 512, 4)
stream_read('dram', 8192, 1)


def stream_case(kind, n=2048, threads=32):
    def run(dev):
        rng = np.random.default_rng(2)
        if kind == 'copy':
            a, b = buf(dev, n), buf(dev, n); x = rng.standard_normal(n).astype(np.float32); dev.write(a, x)
            r = dev.launch(K('stream_copy'), threads=threads, a=a, b=b, n=n, T=threads)
            got = dev.read(b); exact(got.view(np.uint32), x.view(np.uint32), 'copy')
        elif kind == 'triad':
            a, b, c = buf(dev, n), buf(dev, n), buf(dev, n)
            y, z = rng.standard_normal(n).astype(np.float32), rng.standard_normal(n).astype(np.float32)
            dev.write(b, y); dev.write(c, z)
            r = dev.launch(K('stream_triad'), threads=threads, a=a, b=b, c=c, s=1.5, n=n, T=threads)
            got = dev.read(a); close(got, y + np.float32(1.5) * z, what='triad')
        else:
            a = buf(dev, n)
            r = dev.launch(K('memset'), threads=threads, a=a, v=0x5A5A5A5A, n=n, T=threads)
            got = dev.read(a, np.uint32); exact(got, np.full(n, 0x5A5A5A5A, np.uint32), 'memset')
        return r, u32(got)
    arrays = {'copy': 2, 'triad': 3, 'memset': 1}[kind]
    desc = {'copy': 'b[i] = a[i]', 'triad': 'a[i] = b[i] + s*c[i]', 'memset': 'a[i] = v (stores only)'}[kind]
    return case(f'stream_{kind}', 'micro', f'{desc}, n = {n} ({arrays * n} words, > L2)', run, threads,
                mem_words=1 << (arrays * n + 256).bit_length(), elements=n)


for k in ('copy', 'triad', 'memset'): stream_case(k)


def stride_case(S, threads=32, F=1024, iters=32):
    def run(dev):
        a = buf(dev, F); out = buf(dev, threads)
        dev.write(a, np.arange(F, dtype=np.uint32))
        r = dev.launch(K('stride_load'), threads=threads, a=a, out=out, S=S, T=threads, F=F, iters=iters)
        g = np.arange(threads)
        want = sum(((k * threads + g) * S) & (F - 1) for k in range(iters)).astype(np.uint32)
        got = dev.read(out, np.uint32); exact(got, want, 'stride')
        return r, u32(got)
    return case(f'stride_s{S}', 'micro', f'warp lanes {S} word(s) apart (L2-resident 1K-word footprint)', run, threads,
                mem_words=2048, elements=threads * iters)


for s in (1, 2, 4, 8): stride_case(s)


def gather_case(n=1024, F=4096, threads=32):
    def run(dev):
        rng = np.random.default_rng(3)
        a, idx, out = buf(dev, F), buf(dev, n), buf(dev, n)
        x = rng.standard_normal(F).astype(np.float32); j = rng.integers(0, F, n).astype(np.uint32)
        dev.write(a, x); dev.write(idx, j)
        r = dev.launch(K('gather'), threads=threads, a=a, idx=idx, out=out, n=n, T=threads)
        got = dev.read(out); exact(got.view(np.uint32), x[j].view(np.uint32), 'gather')
        return r, u32(got)
    return case('gather', 'micro', f'out[i] = a[idx[i]], random idx over {F} words', run, threads, mem_words=8192,
                elements=n)


gather_case()


def chase_case(tag, lines, iters=256):
    words = lines * 4
    mem = max(1024, 1 << (words + 256).bit_length())

    def run(dev):
        rng = np.random.default_rng(4)
        a, out = buf(dev, words), buf(dev, 1)
        order = rng.permutation(lines)                          # one random cycle through all lines, one hop per line
        nxt = np.zeros(words, np.uint32)
        for i in range(lines): nxt[order[i] * 4] = order[(i + 1) % lines] * 4
        dev.write(a, nxt)
        start = int(order[0] * 4)
        r = dev.launch(K('ptr_chase'), threads=1, a=a, start=start, iters=iters, out=out)
        p = start
        for _ in range(iters): p = int(nxt[p])
        got = dev.read(out, np.uint32); exact(got, [p], 'chase')
        return r, u32(got)
    return case(f'chase_{tag}', 'micro', f'dependent loads, {lines}-line random cycle (fits {tag.upper()})', run, 1,
                mem_words=mem, elements=iters)


chase_case('l1', 8)
chase_case('l2', 128)
chase_case('dram', 2048)


def smem_case(S, threads=32, iters=32):
    def run(dev):
        SH = dev.profile.shared
        out = buf(dev, threads)
        r = dev.launch(K('smem_stride'), threads=threads, out=out, S=S, SH=SH, iters=iters)
        nthr = dev.profile.block; tid = np.arange(threads) % nthr
        want = sum((tid * S + k * nthr * S) & (SH - 1) for k in range(iters)).astype(np.uint32)
        got = dev.read(out, np.uint32); exact(got, want, 'smem')
        return r, u32(got)
    return case(f'smem_s{S}', 'micro', f'shared-memory loads, lanes {S} word(s) apart ({min(S, 4)}-way bank use)',
                run, threads, elements=threads * iters)


for s in (1, 2, 4): smem_case(s)


def atomic_case(bins, threads=32, iters=8, tag=''):
    def run(dev):
        h = buf(dev, max(bins, 4))
        r = dev.launch(K('atomic_hist'), threads=threads, hist=h, bins=bins, T=threads, iters=iters)
        g = np.arange(threads)
        want = np.bincount(np.concatenate([(g + k * threads) & (bins - 1) for k in range(iters)]), minlength=bins)
        got = dev.read(h, np.uint32, words=bins); exact(got, want.astype(np.uint32), f'atomic bins={bins}')
        return r, u32(got)
    where = '2 cores at once' if threads > 16 else 'one block (one core)'
    return case(f'atomic_b{bins}{tag}', 'micro', f'ATOM_ADD into {bins} bin(s), {threads} threads, {where}', run, threads,
                elements=threads * iters)


for b in (1, 4, 64): atomic_case(b)
atomic_case(1, threads=16, iters=16, tag='_1core')


def diverge_case(mask, threads=32, work=32):
    def run(dev):
        out = buf(dev, threads)
        r = dev.launch(K('diverge'), threads=threads, out=out, mask=mask, work=work)
        g = np.arange(threads); tid = g % dev.profile.block
        want = (g + np.where((tid & mask) == 0, work, 0)).astype(np.uint32)
        got = dev.read(out, np.uint32); exact(got, want, 'diverge')
        return r, u32(got)
    frac = {0: 'all', 1: '1/2 of the', 3: '1/4 of the'}[mask]
    return case(f'diverge_m{mask}', 'micro', f'{frac} lanes run a {work}-trip loop, the rest wait at the join', run,
                threads, elements=threads)


for m in (0, 1, 3): diverge_case(m)


def barrier_case(threads=32, iters=64):
    def run(dev):
        out = buf(dev, threads)
        r = dev.launch(K('barrier_loop'), threads=threads, out=out, iters=iters)
        got = dev.read(out, np.uint32); exact(got, np.full(threads, iters, np.uint32), 'barrier')
        return r, u32(got)
    return case('barrier', 'micro', f'{iters} rounds of ADD + SYNC', run, threads, elements=iters)


barrier_case()


# ===================================================================================================== applications
def app_vadd(n=192):
    def run(dev):
        rng = np.random.default_rng(5)
        a, b, c = buf(dev, n), buf(dev, n), buf(dev, n)
        x, y = rng.standard_normal(n).astype(np.float32), rng.standard_normal(n).astype(np.float32)
        dev.write(a, x); dev.write(b, y)
        r = dev.launch(nn_kernel('vadd'), threads=n, a=a, b=b, c=c, n=n)
        got = dev.read(c); close(got, x + y, what='vadd')
        return r, u32(got)
    return case('vadd', 'app', f'c = a + b, {n} elements, thread per element', run, n, elements=n)


def app_matvec(m=64, k=16):
    def run(dev):
        rng = np.random.default_rng(6)
        W, x, b, y = buf(dev, m * k), buf(dev, k), buf(dev, m), buf(dev, m)
        Wv, xv, bv = (rng.standard_normal(s).astype(np.float32) for s in ((m, k), k, m))
        dev.write(W, Wv); dev.write(x, xv); dev.write(b, bv)
        r = dev.launch(nn_kernel('matvec'), threads=m, W=W, x=x, b=b, y=y, m=m, k_dim=k)
        got = dev.read(y); close(got, Wv @ xv + bv, rtol=1e-3, atol=1e-4, what='matvec')
        return r, u32(got)
    return case('matvec', 'app', f'y = W x + b, {m}x{k}, thread per row', run, m, mem_words=2048, elements=m * k)


def app_reduce(threads=192):
    def run(dev):
        rng = np.random.default_rng(7)
        nb = threads // dev.profile.block
        x, out = buf(dev, threads), buf(dev, nb)
        v = rng.integers(-8, 8, threads).astype(np.float32); dev.write(x, v)
        r = dev.launch(nn_kernel('reduce_sum'), threads=threads, x=x, out=out)
        got = dev.read(out); exact(got, v.reshape(nb, -1).sum(1), 'reduce_sum')
        return r, u32(got)
    return case('reduce_sum', 'app', f'per-block sum of {threads} values, shared-memory tree', run, threads,
                elements=threads)


def app_dot(n=2048, threads=64):
    def run(dev):
        rng = np.random.default_rng(8)
        nb = threads // dev.profile.block
        x, y, out = buf(dev, n), buf(dev, n), buf(dev, nb)
        xv, yv = rng.integers(-4, 4, n).astype(np.float32), rng.integers(-4, 4, n).astype(np.float32)
        dev.write(x, xv); dev.write(y, yv)
        r = dev.launch(K('dot'), threads=threads, x=x, y=y, out=out, n=n, T=threads)
        got = dev.read(out); exact(got.sum(), np.float32((xv * yv).sum()), 'dot')
        return r, u32(got)
    return case('dot', 'app', f'x . y, n = {n}: grid-stride FMA + shared-memory tree', run, threads, mem_words=8192,
                elements=n)


def app_gemm(kind, M=12, N=16, Kd=32):
    def run(dev):
        rng = np.random.default_rng(9)
        A, B, C = buf(dev, M * Kd), buf(dev, Kd * N), buf(dev, M * N)
        Av, Bv = rng.standard_normal((M, Kd)).astype(np.float32), rng.standard_normal((Kd, N)).astype(np.float32)
        dev.write(A, Av); dev.write(B, Bv)
        if kind == 'naive':
            r = dev.launch(K('gemm_naive'), threads=M * N, A=A, B=B, C=C, K=Kd, N=N, logN=N.bit_length() - 1)
        else:
            r = dev.launch(K('gemm_smem'), threads=M * N, A=A, B=B, C=C, K=Kd, N=N, logNT=(N // 4).bit_length() - 1)
        got = dev.read(C); close(got, (Av @ Bv).ravel(), rtol=1e-3, atol=1e-3, what='gemm')
        return r, u32(got)
    desc = 'every operand from global memory' if kind == 'naive' else '4x4 tiles staged in shared memory'
    return case(f'gemm_{kind}', 'app', f'C = A B, {M}x{Kd}x{N}, {desc}', run, M * N,
                mem_words=2048, block=16 if kind == 'smem' else None, shared=8 * Kd if kind == 'smem' else 0,
                elements=M * N * Kd)


def app_stencil(n=1026, threads=64):
    def run(dev):
        rng = np.random.default_rng(10)
        x, y = buf(dev, n), buf(dev, n)
        v = rng.standard_normal(n).astype(np.float32); dev.write(x, v)
        r = dev.launch(K('stencil3'), threads=threads, x=x, y=y, n=n, T=threads)
        got = dev.read(y)[1:-1]
        close(got, np.float32(0.25) * v[:-2] + np.float32(0.5) * v[1:-1] + np.float32(0.25) * v[2:], what='stencil')
        return r, u32(got)
    return case('stencil3', 'app', f'3-point stencil, n = {n}', run, threads, mem_words=4096, elements=n - 2)


def app_transpose(kind, R=12, C=16):
    def run(dev):
        src, dst = buf(dev, R * C), buf(dev, R * C)
        v = np.arange(R * C, dtype=np.uint32).reshape(R, C); dev.write(src, v)
        if kind == 'naive':
            r = dev.launch(K('transpose_naive'), threads=R * C, src=src, dst=dst, R=R, C=C, logC=C.bit_length() - 1)
        else:
            r = dev.launch(K('transpose_smem'), threads=R * C, src=src, dst=dst, R=R, C=C,
                           logCT=(C // 4).bit_length() - 1)
        got = dev.read(dst, np.uint32); exact(got, v.T.ravel(), 'transpose')
        return r, u32(got)
    desc = 'strided stores' if kind == 'naive' else '4x4 tiles through shared memory, coalesced both ways'
    return case(f'transpose_{kind}', 'app', f'{R}x{C} transpose, {desc}', run, R * C,
                block=16 if kind == 'smem' else None, elements=R * C)


def app_histogram(n=1024, bins=16, threads=64):
    def run(dev):
        rng = np.random.default_rng(11)
        data, hist = buf(dev, n), buf(dev, bins)
        v = rng.integers(0, bins, n).astype(np.uint32); dev.write(data, v)
        r = dev.launch(K('histogram'), threads=threads, data=data, hist=hist, n=n, T=threads)
        got = dev.read(hist, np.uint32); exact(got, np.bincount(v, minlength=bins).astype(np.uint32), 'histogram')
        return r, u32(got)
    return case('histogram', 'app', f'{bins}-bin histogram of {n} values with ATOM_ADD', run, threads, mem_words=2048,
                elements=n)


def app_scan(threads=128):
    def run(dev):
        rng = np.random.default_rng(12)
        nthr = dev.profile.block
        x, y = buf(dev, threads), buf(dev, threads)
        v = rng.integers(0, 100, threads).astype(np.uint32); dev.write(x, v)
        r = dev.launch(K('prefix_scan'), threads=threads, x=x, y=y)
        got = dev.read(y, np.uint32); exact(got, np.cumsum(v.reshape(-1, nthr), 1).ravel().astype(np.uint32), 'scan')
        return r, u32(got)
    return case('prefix_scan', 'app', f'per-block inclusive scan of {threads} ints (Hillis-Steele)', run, threads,
                elements=threads)


def app_linear(B=32, Kd=16, N=16):
    def run(dev):
        rng = np.random.default_rng(13)
        X, W, b, Y = buf(dev, B * Kd), buf(dev, N * Kd), buf(dev, N), buf(dev, B * N)
        Xv, Wv, bv = (rng.standard_normal(s).astype(np.float32) for s in ((B, Kd), (N, Kd), N))
        dev.write(X, Xv); dev.write(W, Wv); dev.write(b, bv)
        r = dev.launch(nn_kernel('linear_fwd'), threads=B, X=X, W=W, bias=b, Y=Y, B=B, K=Kd, N=N)
        got = dev.read(Y); close(got, (Xv @ Wv.T + bv).ravel(), rtol=1e-3, atol=1e-4, what='linear_fwd')
        return r, u32(got)
    return case('linear_fwd', 'app', f'Y = X W^T + b, batch {B}, {Kd} -> {N}, thread per sample', run, B,
                mem_words=2048, elements=B * Kd * N)


def app_mlp(steps=20, B=16, sizes=(2, 8, 1)):
    def run(dev):
        rng = np.random.default_rng(14)
        Xv = rng.standard_normal((B, sizes[0])).astype(np.float32); Tv = (Xv[:, :1] * Xv[:, 1:2]).astype(np.float32)
        net = FusedMLP(dev, list(sizes), batch=B, init=init_weights(list(sizes), seed=0))
        net.set_data(Xv, Tv)
        loss = net.train(steps, 0.05)
        assert np.isfinite(loss), 'mlp_train loss'
        w = np.concatenate([np.ravel(a) for wb in net.weights() for a in wb])
        return net.last, u32(w)
    return case('mlp_train', 'app', f'fused MLP {"-".join(map(str, sizes))} training, batch {B}, {steps} steps', run,
                B, block=16, elements=steps)


app_vadd(); app_matvec(); app_reduce(); app_dot()
app_gemm('naive'); app_gemm('smem')
app_stencil(); app_transpose('naive'); app_transpose('smem')
app_histogram(); app_scan(); app_linear(); app_mlp()

BY_NAME = {c.name: c for c in CASES}
