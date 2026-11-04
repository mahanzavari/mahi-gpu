"""Kernel tests: each kernel vs NumPy, and every simulator backend bit-identical to the golden model.

  MAHI_BACKENDS=golden,verilator python sw/tests/test_kernels.py      (default: golden, plus verilator if installed)
  MAHI_BACKENDS=golden,xsim       python sw/tests/test_kernels.py      (Vivado machine)
"""
import os, shutil, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
import numpy as np
from mahi import Device, assemble_file

KDIR = os.path.join(HERE, '..', 'kernels')
BACKENDS = os.environ.get('MAHI_BACKENDS', 'golden' + (',verilator' if shutil.which('verilator') else '')).split(',')
PROFILE = os.environ.get('MAHI_PROFILE', 'fpga')
_devs = {}


def dev(backend):
    if backend not in _devs: _devs[backend] = Device(backend, PROFILE)
    d = _devs[backend]; d.free_all(); d.mem[:] = [0] * len(d.mem)
    return d


def kernel(name): return assemble_file(os.path.join(KDIR, name + '.s'))


def run_all(fn):
    """fn(device) -> (result array, cycles); returns {backend: (result, cycles)}"""
    return {b: fn(dev(b)) for b in BACKENDS}


class Kernels(unittest.TestCase):
    def check(self, res, ref, rtol=1e-5, atol=1e-6):
        g = res['golden'][0]
        np.testing.assert_allclose(g, ref, rtol=rtol, atol=atol)
        for b, (r, cyc) in res.items():
            self.assertTrue(np.array_equal(r.view(np.uint32), g.view(np.uint32)), f'{b} differs from golden')
            if b != 'golden': print(f'  {self._testMethodName} {b}: {cyc} cycles')

    def test_vadd(self):
        rng = np.random.default_rng(1); n = 37
        a, b = rng.standard_normal(n).astype(np.float32), rng.standard_normal(n).astype(np.float32)
        k = kernel('vadd')

        def go(d):
            A, B, C = d.alloc(n), d.alloc(n), d.alloc(n)
            d.write(A, a); d.write(B, b)
            r = d.launch(k, threads=48, a=A, b=B, c=C, n=n)     # 3 blocks, last one partly idle
            return d.read(C), r.cycles
        self.check(run_all(go), a + b)

    def test_matvec(self):
        rng = np.random.default_rng(2); m, kd = 12, 9
        W = rng.standard_normal((m, kd)).astype(np.float32)
        x = rng.standard_normal(kd).astype(np.float32); bias = rng.standard_normal(m).astype(np.float32)
        k = kernel('matvec')

        def go(d):
            Wb, xb, bb, yb = d.alloc(m * kd), d.alloc(kd), d.alloc(m), d.alloc(m)
            d.write(Wb, W); d.write(xb, x); d.write(bb, bias)
            r = d.launch(k, threads=16, W=Wb, x=xb, b=bb, y=yb, m=m, k_dim=kd)
            return d.read(yb), r.cycles
        self.check(run_all(go), W @ x + bias, rtol=1e-4, atol=1e-5)   # truncating FMA vs round-to-nearest

    def test_reduce_sum(self):
        rng = np.random.default_rng(3); blk = Device('golden', PROFILE).profile.block; nb = 3
        x = rng.standard_normal(nb * blk).astype(np.float32)
        k = kernel('reduce_sum')

        def go(d):
            X, O = d.alloc(nb * blk), d.alloc(nb)
            d.write(X, x)
            r = d.launch(k, threads=nb * blk, x=X, out=O)
            return d.read(O), r.cycles
        self.check(run_all(go), x.reshape(nb, blk).sum(1), rtol=1e-4, atol=1e-5)


if __name__ == '__main__':
    print('backends:', BACKENDS, 'profile:', PROFILE)
    unittest.main(verbosity=2)
