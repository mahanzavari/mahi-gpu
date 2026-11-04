"""Tiny neural-network framework on the mahi-gpu runtime: an MLP (Linear + ReLU hidden layers, linear output) trained
with mean squared error and plain SGD. Every forward, backward and update step is a kernel launch (sw/kernels/*.s); the
host only writes the data once and reads the loss.

    dev = Device('golden', heap_base=64)
    net = MLP(dev, [2, 4, 1], batch=4, seed=0)
    net.set_data(X, T)
    for step in range(500): loss = net.train_step(lr=0.1)
    print(net.predict(X))

`RefMLP` is the same network in NumPy float32 (round-to-nearest, unlike the GPU's truncating FP32), for comparison.
"""
import os

import numpy as np

from .asm import assemble_file
from .runtime import Device, DeviceError

KDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'kernels')
_cache = {}


def kernel(name):
    if name not in _cache: _cache[name] = assemble_file(os.path.join(KDIR, name + '.s'))
    return _cache[name]


def init_weights(sizes, seed=0, scale=None):
    """He-style init: W ~ N(0, 2/fan_in), b = 0.1 (so ReLU units start alive)."""
    rng = np.random.default_rng(seed); out = []
    for k, n in zip(sizes[:-1], sizes[1:]):
        s = scale if scale is not None else np.sqrt(2.0 / k)
        out.append((rng.standard_normal((n, k)).astype(np.float32) * np.float32(s), np.full(n, 0.1, np.float32)))
    return out


class MLP:
    def __init__(self, dev: Device, sizes, batch, seed=0, init=None):
        if batch > 255: raise DeviceError('batch must be <= 255 (one thread per sample)')
        self.dev, self.sizes, self.B = dev, list(sizes), batch
        B = batch
        self.X = dev.alloc(B * sizes[0], 'X'); self.T = dev.alloc(B * sizes[-1], 'T')
        self.E = dev.alloc(B * sizes[-1], 'E')
        self.layers = []
        for li, (k, n) in enumerate(zip(sizes[:-1], sizes[1:])):
            L = dict(K=k, N=n, W=dev.alloc(n * k, f'W{li}'), b=dev.alloc(n, f'b{li}'),
                     dW=dev.alloc(n * k, f'dW{li}'), db=dev.alloc(n, f'db{li}'),
                     Z=dev.alloc(B * n, f'Z{li}'), dZ=dev.alloc(B * n, f'dZ{li}'),
                     A=dev.alloc(B * n, f'A{li}') if li < len(sizes) - 2 else None)
            self.layers.append(L)
        self.set_weights(init if init is not None else init_weights(sizes, seed))
        self.launches = 0; self.cycles = 0

    # ---- host <-> device
    def set_weights(self, wb):
        for L, (W, b) in zip(self.layers, wb):
            self.dev.write(L['W'], np.asarray(W, np.float32)); self.dev.write(L['b'], np.asarray(b, np.float32))

    def weights(self):
        return [(self.dev.read(L['W']).reshape(L['N'], L['K']), self.dev.read(L['b'])) for L in self.layers]

    def set_data(self, X, T):
        X = np.asarray(X, np.float32).reshape(self.B, self.sizes[0])
        T = np.asarray(T, np.float32).reshape(self.B, self.sizes[-1])
        self.dev.write(self.X, X); self.dev.write(self.T, T)

    def _run(self, name, threads, **params):
        r = self.dev.launch(kernel(name), threads=threads, **params)
        self.launches += 1; self.cycles += r.cycles or 0
        return r

    # ---- passes
    def forward(self):
        a = self.X
        for li, L in enumerate(self.layers):
            self._run('linear_fwd', self.B, X=a, W=L['W'], bias=L['b'], Y=L['Z'], B=self.B, K=L['K'], N=L['N'])
            if L['A'] is not None:
                self._run('relu_fwd', self.B * L['N'], X=L['Z'], Y=L['A'], n=self.B * L['N'])
                a = L['A']
        return self.layers[-1]['Z']

    def loss_and_grad(self):
        n = self.B * self.sizes[-1]; last = self.layers[-1]
        self._run('mse', n, Y=last['Z'], T=self.T, dY=last['dZ'], E=self.E, n=n, scale=float(np.float32(2.0 / n)))
        return float(np.sum(self.dev.read(self.E), dtype=np.float64) / n)

    def backward(self):
        for li in range(len(self.layers) - 1, -1, -1):
            L = self.layers[li]
            a_in = self.X if li == 0 else self.layers[li - 1]['A']
            self._run('linear_bwd_w', L['N'], dY=L['dZ'], X=a_in, dW=L['dW'], db=L['db'], B=self.B, K=L['K'], N=L['N'])
            if li > 0:
                P = self.layers[li - 1]
                self._run('linear_bwd_x', self.B, dY=L['dZ'], W=L['W'], dX=P['dZ'], B=self.B, K=L['K'], N=L['N'])
                self._run('relu_bwd', self.B * P['N'], Z=P['Z'], dY=P['dZ'], dX=P['dZ'], n=self.B * P['N'])

    def sgd(self, lr):
        nlr = float(np.float32(-lr))
        for L in self.layers:
            self._run('sgd', L['N'] * L['K'], P=L['W'], G=L['dW'], neg_lr=nlr, n=L['N'] * L['K'])
            self._run('sgd', L['N'], P=L['b'], G=L['db'], neg_lr=nlr, n=L['N'])

    def train_step(self, lr):
        self.forward(); loss = self.loss_and_grad(); self.backward(); self.sgd(lr)
        return loss

    def predict(self, X):
        self.dev.write(self.X, np.asarray(X, np.float32).reshape(self.B, self.sizes[0]))
        return self.dev.read(self.forward()).reshape(self.B, self.sizes[-1])


class RefMLP:
    """The same network and the same operation order in NumPy float32 (IEEE round-to-nearest)."""
    def __init__(self, sizes, init):
        self.sizes = sizes; self.wb = [(np.array(W, np.float32), np.array(b, np.float32)) for W, b in init]

    def train_step(self, X, T, lr):
        X = np.asarray(X, np.float32); T = np.asarray(T, np.float32)
        acts, zs = [X], []
        for li, (W, b) in enumerate(self.wb):
            z = (acts[-1] @ W.T + b).astype(np.float32); zs.append(z)
            if li < len(self.wb) - 1: acts.append(np.maximum(z, np.float32(0)))
        n = T.size; d = zs[-1] - T
        loss = float(np.sum(d * d, dtype=np.float64) / n)
        dz = (d * np.float32(2.0 / n)).astype(np.float32)
        grads = [None] * len(self.wb)
        for li in range(len(self.wb) - 1, -1, -1):
            W, b = self.wb[li]
            grads[li] = ((dz.T @ acts[li]).astype(np.float32), dz.sum(0).astype(np.float32))
            if li > 0: dz = ((dz @ W) * (zs[li - 1] > 0)).astype(np.float32)
        self.wb = [((W - np.float32(lr) * gW).astype(np.float32), (b - np.float32(lr) * gb).astype(np.float32))
                   for (W, b), (gW, gb) in zip(self.wb, grads)]
        return loss

    def predict(self, X):
        a = np.asarray(X, np.float32)
        for li, (W, b) in enumerate(self.wb):
            a = (a @ W.T + b).astype(np.float32)
            if li < len(self.wb) - 1: a = np.maximum(a, np.float32(0))
        return a


class FusedMLP:
    """One-hidden-layer MLP (IN -> H ReLU -> OUT) trained by a single kernel launch per `steps` training steps
    (kernels/mlp_train.s). Bit-identical to MLP with the same sizes, init and learning rate; the batch must fit one
    block (B <= profile block size) because the steps synchronize with SYNC."""
    def __init__(self, dev: Device, sizes, batch, seed=0, init=None):
        if len(sizes) != 3: raise DeviceError('FusedMLP has exactly one hidden layer: sizes = [IN, H, OUT]')
        if batch > dev.profile.block:
            raise DeviceError(f'batch {batch} > block size {dev.profile.block}: the fused kernel needs one block')
        self.dev, self.sizes, self.B = dev, list(sizes), batch
        IN, H, OUT = sizes; B = batch
        self.X = dev.alloc(B * IN, 'X'); self.T = dev.alloc(B * OUT, 'T')
        self.P = dev.alloc(H * IN + H + OUT * H + OUT, 'P')
        self.S = dev.alloc(2 * B * H + B * OUT + 2 * B, 'S')
        self.set_weights(init if init is not None else init_weights(sizes, seed))
        self.launches = 0; self.cycles = 0; self.steps_done = 0

    def set_weights(self, wb):
        (W1, b1), (W2, b2) = wb
        self.dev.write(self.P, np.concatenate([np.ravel(W1), np.ravel(b1), np.ravel(W2), np.ravel(b2)]).astype(np.float32))

    def weights(self):
        IN, H, OUT = self.sizes; p = self.dev.read(self.P); o = 0
        W1 = p[o:o + H * IN].reshape(H, IN); o += H * IN
        b1 = p[o:o + H]; o += H
        W2 = p[o:o + OUT * H].reshape(OUT, H); o += OUT * H
        return [(W1, b1), (W2, p[o:o + OUT])]

    def set_data(self, X, T):
        self.dev.write(self.X, np.asarray(X, np.float32).reshape(self.B, self.sizes[0]))
        self.dev.write(self.T, np.asarray(T, np.float32).reshape(self.B, self.sizes[-1]))

    def train(self, steps, lr):
        """run `steps` training steps in one launch; returns the loss of the last step"""
        IN, H, OUT = self.sizes; B = self.B; n = B * OUT
        r = self.dev.launch(kernel('mlp_train'), threads=B, X=self.X, T=self.T, P=self.P, S=self.S, B=B, IN=IN, H=H,
                            OUT=OUT, steps=steps, neg_lr=float(np.float32(-lr)), scale=float(np.float32(2.0 / n)),
                            h_iters=-(-H // B), o_iters=-(-OUT // B))
        self.launches += 1; self.cycles += r.cycles or 0; self.steps_done += steps
        E = self.dev.read(self.S, offset=2 * B * H + B * OUT, words=B)
        return float(np.sum(E, dtype=np.float64) / n)
