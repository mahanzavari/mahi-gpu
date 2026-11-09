"""NN kernels (M3) and the MLP framework: each kernel vs NumPy, every backend bit-identical to the golden model,
and a few full training steps (forward, MSE, backward, SGD) bit-identical across backends.

  python sw/tests/test_nn.py          (backends: golden, plus verilator if installed; MAHI_BACKENDS / MAHI_PROFILE as
                                       in test_kernels.py)
"""
import os, shutil, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
import numpy as np
from mahi import Device
from mahi.nn import kernel, MLP, FusedMLP, RefMLP, init_weights

BACKENDS = os.environ.get('MAHI_BACKENDS', 'golden' + (',verilator' if shutil.which('verilator') else '')).split(',')
PROFILE = os.environ.get('MAHI_PROFILE', 'fpga')
_devs = {}


def dev(backend):
    if backend not in _devs: _devs[backend] = Device(backend, PROFILE, heap_base=64)
    d = _devs[backend]; d.free_all(); d.mem[:] = [0] * len(d.mem)
    return d


def f32(rng, *shape): return rng.standard_normal(shape).astype(np.float32)


class NNKernels(unittest.TestCase):
    def same_everywhere(self, fn, ref, rtol=1e-4, atol=1e-5):
        res = {b: fn(dev(b)) for b in BACKENDS}
        g = res['golden']
        for x, r in zip(g, ref): np.testing.assert_allclose(x, r, rtol=rtol, atol=atol)
        for b, outs in res.items():
            for x, y in zip(outs, g):
                self.assertTrue(np.array_equal(x.view(np.uint32), y.view(np.uint32)), f'{b} differs from golden')

    def test_linear_fwd(self):
        rng = np.random.default_rng(10); B, K, N = 5, 3, 4
        X, W, b = f32(rng, B, K), f32(rng, N, K), f32(rng, N)

        def go(d):
            Xb, Wb, bb, Yb = d.alloc(B * K), d.alloc(N * K), d.alloc(N), d.alloc(B * N)
            d.write(Xb, X); d.write(Wb, W); d.write(bb, b)
            d.launch(kernel('linear_fwd'), threads=B, X=Xb, W=Wb, bias=bb, Y=Yb, B=B, K=K, N=N)
            return [d.read(Yb)]
        self.same_everywhere(go, [(X @ W.T + b).ravel()])

    def test_linear_bwd(self):
        rng = np.random.default_rng(11); B, K, N = 6, 4, 3
        dY, X, W = f32(rng, B, N), f32(rng, B, K), f32(rng, N, K)

        def go(d):
            dYb, Xb, Wb = d.alloc(B * N), d.alloc(B * K), d.alloc(N * K)
            dXb, dWb, dbb = d.alloc(B * K), d.alloc(N * K), d.alloc(N)
            d.write(dYb, dY); d.write(Xb, X); d.write(Wb, W)
            d.launch(kernel('linear_bwd_x'), threads=B, dY=dYb, W=Wb, dX=dXb, B=B, K=K, N=N)
            d.launch(kernel('linear_bwd_w'), threads=N, dY=dYb, X=Xb, dW=dWb, db=dbb, B=B, K=K, N=N)
            return [d.read(dXb), d.read(dWb), d.read(dbb)]
        self.same_everywhere(go, [(dY @ W).ravel(), (dY.T @ X).ravel(), dY.sum(0)])

    def test_relu_mse_sgd(self):
        rng = np.random.default_rng(12); n = 40
        Z, dA, Y, T, P, G = (f32(rng, n) for _ in range(6))
        Z[:3] = [0.0, -0.0, 1e-30]                        # zeros and a value that flushes on the GPU side

        def go(d):
            Zb, Ab, dAb, dZb, Yb, Tb, dYb, Eb, Pb, Gb = (d.alloc(n) for _ in range(10))
            for buf, v in ((Zb, Z), (dAb, dA), (Yb, Y), (Tb, T), (Pb, P), (Gb, G)): d.write(buf, v)
            d.launch(kernel('relu_fwd'), threads=n, X=Zb, Y=Ab, n=n)
            d.launch(kernel('relu_bwd'), threads=n, Z=Zb, dY=dAb, dX=dZb, n=n)
            d.launch(kernel('mse'), threads=n, Y=Yb, T=Tb, dY=dYb, E=Eb, n=n, scale=0.05)
            d.launch(kernel('sgd'), threads=n, P=Pb, G=Gb, neg_lr=-0.1, n=n)
            return [d.read(Ab), d.read(dZb), d.read(Eb), d.read(dYb), d.read(Pb)]
        relu = np.maximum(Z, 0); relu[:3] = 0                # -0.0 -> +0.0 and the tiny value: compare as 0
        dz = np.where(Z > 0, dA, 0).astype(np.float32); dz[2] = dA[2]
        dd = Y - T
        self.same_everywhere(go, [relu, dz, dd * dd, dd * np.float32(0.05), P + np.float32(-0.1) * G], atol=1e-6)


class Training(unittest.TestCase):
    def test_steps_match_reference_and_backends(self):
        X = np.array([[0, 0], [0, 1], [1, 0], [1, 1]], np.float32); T = np.array([[0], [1], [1], [0]], np.float32)
        init = init_weights([2, 4, 1], seed=3)
        ref = RefMLP([2, 4, 1], init)
        steps = 4
        ref_losses = [ref.train_step(X, T, 0.1) for _ in range(steps)]
        results = {}
        for b in BACKENDS:
            net = MLP(dev(b), [2, 4, 1], batch=4, init=init)
            net.set_data(X, T)
            losses = [net.train_step(0.1) for _ in range(steps)]
            results[b] = (losses, net.weights())
            if b != 'golden': print(f'  training step on {b}: {net.cycles // steps} cycles, {net.launches // steps} launches')
        g_losses, g_w = results['golden']
        np.testing.assert_allclose(g_losses, ref_losses, rtol=1e-3)
        for (W, bb), (rW, rb) in zip(g_w, ref.wb):
            np.testing.assert_allclose(W, rW, rtol=1e-3, atol=1e-5); np.testing.assert_allclose(bb, rb, rtol=1e-3, atol=1e-5)
        for b, (losses, w) in results.items():
            self.assertEqual(losses, g_losses, f'{b} loss differs from golden')
            for (W, bb), (gW, gb) in zip(w, g_w):
                self.assertTrue(np.array_equal(W.view(np.uint32), gW.view(np.uint32)) and
                                np.array_equal(bb.view(np.uint32), gb.view(np.uint32)), f'{b} weights differ')


class Fused(unittest.TestCase):
    """the fused training kernel gives exactly the weights of the unfused MLP (same arithmetic, same order)"""
    def run_case(self, sizes, B, lr, steps, chunks, seed):
        if B > dev('golden').profile.block: self.skipTest(f'batch {B} > block size of profile {PROFILE}')
        rng = np.random.default_rng(seed)
        X = rng.standard_normal((B, sizes[0])).astype(np.float32); T = rng.standard_normal((B, sizes[-1])).astype(np.float32)
        init = init_weights(sizes, seed=seed)
        g = dev('golden'); ref = MLP(g, sizes, batch=B, init=init); ref.set_data(X, T)
        ref_losses = [ref.train_step(lr) for _ in range(steps)]
        want = ref.weights()
        for b in BACKENDS:
            d = dev(b); net = FusedMLP(d, sizes, batch=B, init=init); net.set_data(X, T)
            per = steps // chunks; loss = None
            for _ in range(chunks): loss = net.train(per, lr)
            for (W, c), (rW, rc) in zip(net.weights(), want):
                self.assertTrue(np.array_equal(W.view(np.uint32), rW.view(np.uint32)) and
                                np.array_equal(c.view(np.uint32), rc.view(np.uint32)), f'{b}: fused weights differ')
            if sizes[-1] == 1: self.assertEqual(loss, ref_losses[-1], f'{b}: last-step loss differs')
            if b != 'golden': print(f'  fused {sizes} B={B} on {b}: {net.cycles // steps} cycles/step, {net.launches} launches')

    def test_xor_shape(self): self.run_case([2, 4, 1], 4, 0.1, 6, 2, 1)

    def test_more_rows_than_threads(self): self.run_case([3, 7, 5], 4, 0.05, 4, 1, 2)   # H, OUT > B: masked rows

    def test_full_block(self): self.run_case([1, 8, 1], 16, 0.02, 4, 2, 3)


if __name__ == '__main__':
    print('backends:', BACKENDS, 'profile:', PROFILE)
    unittest.main(verbosity=2)
