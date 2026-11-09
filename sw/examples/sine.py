#!/usr/bin/env python3
"""Fit sin(x) on [-pi, pi] with a 1-H-1 ReLU MLP on mahi-gpu: 16 samples, one GPU thread per sample (one full block on
the FPGA profile), MSE + SGD, every step a set of kernel launches. Compared with the same network in NumPy float32.

  python sw/examples/sine.py                                      # golden model
  python sw/examples/sine.py --compare golden,verilator           # RTL simulation, bit-identical check
"""
import argparse, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import numpy as np
from mahi import Device
from mahi.nn import MLP, FusedMLP, RefMLP, init_weights


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--backend', default='golden'); ap.add_argument('--compare', default=None)
    ap.add_argument('--fused', action='store_true', help='one kernel launch per --every steps (kernels/mlp_train.s)')
    ap.add_argument('--profile', default='fpga'); ap.add_argument('--steps', type=int, default=3000)
    ap.add_argument('--lr', type=float, default=0.02); ap.add_argument('--hidden', type=int, default=8)
    ap.add_argument('--seed', type=int, default=2); ap.add_argument('--samples', type=int, default=16)
    ap.add_argument('--every', type=int, default=500); ap.add_argument('--target', type=float, default=0.01)
    a = ap.parse_args()
    x = np.linspace(-np.pi, np.pi, a.samples, dtype=np.float32).reshape(-1, 1); t = np.sin(x).astype(np.float32)
    sizes = [1, a.hidden, 1]; init = init_weights(sizes, seed=a.seed)
    print(f'sin(x) fit, MLP 1-{a.hidden}-1 ({sum(W.size + b.size for W, b in init)} parameters), {a.samples} samples, '
          f'SGD lr={a.lr}, {a.steps} steps, profile {a.profile}')
    ref = RefMLP(sizes, init); ref_l = [ref.train_step(x, t, a.lr) for _ in range(a.steps)]
    print(f'  [numpy f32] final MSE {ref_l[-1]:.5f}')
    runs = {}
    for b in (a.compare.split(',') if a.compare else [a.backend]):
        dev = Device(b, a.profile, heap_base=64)
        net = (FusedMLP if a.fused else MLP)(dev, sizes, batch=a.samples, init=init); net.set_data(x, t)
        L, t0, s = [], time.time(), 0
        while s < a.steps:
            if a.fused:                       # one launch per chunk; the loss of the chunk's last step
                n = min(a.every, a.steps - s); L += [None] * (n - 1) + [net.train(n, a.lr)]; s += n
            else:
                L.append(net.train_step(a.lr)); s += 1
            if a.fused or (s - 1) % a.every == 0 or s == a.steps: print(f'  [{b}] step {s - 1:5d}  MSE {L[-1]:.5f}')
        pred = (MLP(dev, sizes, batch=a.samples, init=net.weights()) if a.fused else net).predict(x).ravel()
        runs[b] = (net, L)
        cyc = f', {net.cycles:,} GPU cycles ({net.cycles // a.steps:,}/step)' if net.cycles else ''
        print(f'  [{b}] final MSE {L[-1]:.5f} ({"below" if L[-1] < a.target else "ABOVE"} target {a.target}), '
              f'max |MSE - numpy| {max(abs(p - q) for p, q in zip(L, ref_l) if p is not None):.2e}, max |pred - sin| '
              f'{np.max(np.abs(pred - t.ravel())):.3f}  ({net.launches:,} launches{cyc}, {time.time() - t0:.1f} s wall)')
    names = list(runs)
    for b in names[1:]:
        same = runs[b][1] == runs[names[0]][1] and all(
            np.array_equal(W.view(np.uint32), gW.view(np.uint32)) and np.array_equal(c.view(np.uint32), gc.view(np.uint32))
            for (W, c), (gW, gc) in zip(runs[b][0].weights(), runs[names[0]][0].weights()))
        print(f'  {b} vs {names[0]}: {"losses and weights bit-identical" if same else "DIFFER"}')


if __name__ == '__main__':
    main()
