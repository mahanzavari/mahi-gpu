#!/usr/bin/env python3
"""Train a 2-H-1 MLP on XOR on mahi-gpu (every forward, backward and SGD step is a GPU kernel), next to the same
network in NumPy float32.

  python sw/examples/xor.py                          # golden model
  python sw/examples/xor.py --backend verilator      # RTL simulation, reports cycles
  python sw/examples/xor.py --backend xsim           # Vivado simulator
  python sw/examples/xor.py --compare golden,verilator --steps 300   # bit-identical check between backends
"""
import argparse, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import numpy as np
from mahi import Device
from mahi.nn import MLP, FusedMLP, RefMLP, init_weights

X = np.array([[0, 0], [0, 1], [1, 0], [1, 1]], np.float32)
T = np.array([[0], [1], [1], [0]], np.float32)


def train(backend, a, init, log=True):
    dev = Device(backend, a.profile, heap_base=64)
    cls = FusedMLP if a.fused else MLP
    net = cls(dev, [2, a.hidden, 1], batch=4, init=init)
    net.set_data(X, T)
    losses, t0, s = [], time.time(), 0
    while s < a.steps:
        if a.fused:                                   # one launch for a chunk of steps; loss of its last step
            n = min(a.every, a.steps - s); loss = net.train(n, a.lr); s += n
            losses += [None] * (n - 1) + [loss]
        else:
            loss = net.train_step(a.lr); losses.append(loss); s += 1
        if log and (a.fused or (s - 1) % a.every == 0 or s == a.steps):
            print(f'  [{backend}] step {s - 1:5d}  loss {loss:.6f}')
    pred = net.predict(X).ravel() if not a.fused else predict(net, init_dev=dev)
    return net, losses, pred, time.time() - t0


def predict(net, init_dev):
    """forward pass with the fused net's weights (the unfused kernels on the same device)"""
    m = MLP(init_dev, net.sizes, batch=4, init=net.weights())
    return m.predict(X).ravel()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--backend', default='golden'); ap.add_argument('--compare', default=None)
    ap.add_argument('--fused', action='store_true', help='one kernel launch per --every steps (kernels/mlp_train.s)')
    ap.add_argument('--profile', default='fpga'); ap.add_argument('--steps', type=int, default=600)
    ap.add_argument('--lr', type=float, default=0.1); ap.add_argument('--hidden', type=int, default=4)
    ap.add_argument('--seed', type=int, default=0); ap.add_argument('--every', type=int, default=100)
    a = ap.parse_args()
    init = init_weights([2, a.hidden, 1], seed=a.seed)
    nparams = sum(W.size + b.size for W, b in init)
    print(f'XOR, MLP 2-{a.hidden}-1 ({nparams} parameters), MSE, SGD lr={a.lr}, {a.steps} steps, profile {a.profile}')

    ref = RefMLP([2, a.hidden, 1], init)
    ref_losses = [ref.train_step(X, T, a.lr) for _ in range(a.steps)]
    print(f'  [numpy f32] final loss {ref_losses[-1]:.6f}  outputs {np.round(ref.predict(X).ravel(), 3)}')

    backends = a.compare.split(',') if a.compare else [a.backend]
    runs = {}
    for b in backends:
        net, losses, pred, dt = train(b, a, init)
        runs[b] = (net, losses, pred)
        ok = np.all((pred > 0.5) == (T.ravel() > 0.5))
        cyc = f', {net.cycles:,} GPU cycles ({net.cycles // a.steps:,}/step)' if net.cycles else ''
        print(f'  [{b}] final loss {losses[-1]:.6f}  outputs {np.round(pred, 3)}  XOR {"correct" if ok else "WRONG"}'
              f'  ({net.launches:,} launches{cyc}, {dt:.1f} s wall)')
        print(f'  [{b}] max |loss - numpy| over the run: {max(abs(x - y) for x, y in zip(losses, ref_losses) if x is not None):.2e}')
    if len(runs) > 1:
        g = backends[0]
        for b in backends[1:]:
            same_loss = runs[b][1] == runs[g][1]
            same_w = all(np.array_equal(W.view(np.uint32), gW.view(np.uint32)) and
                         np.array_equal(bb.view(np.uint32), gb.view(np.uint32))
                         for (W, bb), (gW, gb) in zip(runs[b][0].weights(), runs[g][0].weights()))
            print(f'  {b} vs {g}: losses {"identical" if same_loss else "DIFFER"}, '
                  f'final weights {"bit-identical" if same_w else "DIFFER"}')


if __name__ == '__main__':
    main()
