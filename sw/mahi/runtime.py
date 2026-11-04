"""mahi-gpu runtime: device memory, kernel launch, and three interchangeable backends.

    import numpy as np
    from mahi import Device, assemble_file
    dev = Device('golden')                       # or 'verilator' (Linux) / 'xsim' (Vivado, Windows or Linux)
    k = assemble_file('sw/kernels/vadd.s')
    a = dev.alloc(16); b = dev.alloc(16); c = dev.alloc(16)
    dev.write(a, np.arange(16, dtype=np.float32)); dev.write(b, np.ones(16, np.float32))
    r = dev.launch(k, threads=16, a=a, b=b, c=c, n=16)
    print(dev.read(c, np.float32), r.cycles)

Memory model. The device has the 1024-word data memory of the simulation harness (src/tb/random/tb_random.sv). The
runtime keeps a host-side copy; every launch sends the whole image to the backend and reads it back afterwards, so
write/read are plain copies and need no device round trip. Layout: words 0..15 parameter block (kernel arguments, see
`.param` in asm.py), then the kernel's .data section, then the heap from `heap_base` (default 512) upward.

Launch. `threads` is the total thread count (the DCR value, at most 255). The dispatcher splits it into blocks of
`profile.block` threads (warps x lanes per core); a thread sees r29 = block id, r30 = threads per block (always
`profile.block`, also in a partly filled last block), r31 = thread id in its block. Blocks run on any core and may run
in parallel, so blocks must not depend on each other's memory within one launch.

Backends.
  golden     ASIC/scripts/isa.py, in process: bit-exact semantics (including the truncating FP32), no timing. Blocks run
             one after another.
  verilator  FPGA/src/rtl + FPGA/src/tb/random/tb_random.sv built with Verilator (cached under sw/build/); reports cycles.
  xsim       the same testbench with Vivado's simulator, through FPGA/sim/xsim_run.py; reports cycles.
"""
import os, re, shutil, struct, subprocess, sys, tempfile, types

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'ASIC', 'scripts'))
sys.path.insert(0, os.path.join(REPO, 'FPGA', 'sim'))
from isa import Machine, Fault  # noqa: E402

from .asm import Program, fbits, bitsf, PARAM_WORDS  # noqa: E402

DMEM_WORDS = 1024
PROFILES = {   # gpu_pkg.sv: block = warps x lanes per core
    'fpga':      dict(defines=['TARGET_FPGA'], block=16, cores=2, shared=256),
    'sim':       dict(defines=[], block=16, cores=2, shared=256),
    'asic':      dict(defines=['TARGET_ASIC'], block=8, cores=1, shared=64),
    'asic_mini': dict(defines=['TARGET_ASIC', 'TARGET_ASIC_MINI'], block=4, cores=1, shared=32),
}
RTL_DIR = os.path.join(REPO, 'FPGA', 'src', 'rtl')
TB_RANDOM = os.path.join(REPO, 'FPGA', 'src', 'tb', 'random', 'tb_random.sv')
BUILD = os.path.join(REPO, 'sw', 'build')


class DeviceError(Exception):
    pass


class Buffer:
    def __init__(self, addr, words, name=None):
        self.addr, self.words, self.name = addr, words, name

    def __int__(self): return self.addr

    def __repr__(self): return f'Buffer({self.name or "?"} @{self.addr}, {self.words} words)'


class LaunchResult:
    def __init__(self, cycles=None, fault=None, log=''):
        self.cycles, self.fault, self.log = cycles, fault, log

    def __repr__(self): return f'LaunchResult(cycles={self.cycles}, fault={self.fault!r})'


def to_words(values):
    a = np.asarray(values)
    if a.dtype.kind == 'f': return [int(x) for x in np.asarray(a, np.float32).view(np.uint32).ravel()]
    return [int(x) & 0xFFFFFFFF for x in a.ravel()]


def from_words(words, dtype):
    u = np.asarray(words, dtype=np.uint32)
    return u.view(np.float32).copy() if np.dtype(dtype) == np.float32 else u.view(np.dtype(dtype)).copy()


class Device:
    def __init__(self, backend='golden', profile='fpga', heap_base=512, **backend_opts):
        if profile not in PROFILES: raise DeviceError(f'unknown profile {profile} ({", ".join(PROFILES)})')
        self.profile_name, self.profile = profile, types.SimpleNamespace(**PROFILES[profile])
        self.mem = [0] * DMEM_WORDS
        self.heap_base = self.heap = heap_base
        self.backend = {'golden': GoldenBackend, 'verilator': VerilatorBackend, 'xsim': XsimBackend}[backend](
            self.profile_name, self.profile, **backend_opts)

    # ---- memory
    def alloc(self, words, name=None):
        if self.heap + words > DMEM_WORDS: raise DeviceError(f'out of device memory ({words} words requested)')
        b = Buffer(self.heap, words, name); self.heap += words
        return b

    def free_all(self): self.heap = self.heap_base

    def write(self, dst, values, offset=0):
        w = to_words(values); a = int(dst) + offset
        if isinstance(dst, Buffer) and offset + len(w) > dst.words: raise DeviceError(f'{len(w)} words do not fit {dst}')
        if a + len(w) > DMEM_WORDS: raise DeviceError('write past the end of device memory')
        self.mem[a:a + len(w)] = w

    def read(self, src, dtype=np.float32, words=None, offset=0):
        n = words if words is not None else (src.words - offset if isinstance(src, Buffer) else 1)
        a = int(src) + offset
        return from_words(self.mem[a:a + n], dtype)

    # ---- launch
    def launch(self, prog: Program, threads, check_fault=True, **params):
        if not 1 <= threads <= 255: raise DeviceError('threads must be 1..255 (DCR thread count is 8 bits)')
        unknown = set(params) - set(prog.params)
        missing = set(prog.params) - set(params)
        if unknown or missing:
            raise DeviceError(f'kernel params {prog.params}: unknown {sorted(unknown)}, missing {sorted(missing)}')
        if prog.data and prog.data_end() > self.heap_base:
            raise DeviceError(f'kernel data ends at {prog.data_end()}, above heap_base {self.heap_base}')
        for slot, name in enumerate(prog.params):
            v = params[name]
            self.mem[slot] = (fbits(v) if isinstance(v, float) else int(v)) & 0xFFFFFFFF
        for a, w in prog.data.items(): self.mem[a] = w
        res = self.backend.run(prog.text, self.mem, threads)
        if check_fault and res.fault: raise DeviceError(f'kernel fault: {res.fault}')
        return res


# ---- backends --------------------------------------------------------------------------------------------------------
class GoldenBackend:
    def __init__(self, profile_name, profile, max_steps=5_000_000):
        self.p, self.max_steps = profile, max_steps

    def run(self, text, mem, threads):
        p = self.p
        memd = {i: w for i, w in enumerate(mem) if w}

        class M(Machine):
            SHARED_WORDS = p.shared
        nblocks = (threads + p.block - 1) // p.block
        try:
            for b in range(nblocks):
                active = min(p.block, threads - b * p.block)
                m = M(text, memd, nthreads=p.block, block_id=b, max_steps=self.max_steps)  # r30 = block size
                out = {}
                gens = {t: m.thread(t, out) for t in range(active)}
                while gens:
                    waiting, finished = [], []
                    for t, g in list(gens.items()):
                        try:
                            next(g); waiting.append(t)
                        except StopIteration:
                            finished.append(t); del gens[t]
                    if waiting and finished:
                        raise Fault('barrier reached by only a subset of threads (others exited)')
        except Fault as e:
            return LaunchResult(fault=str(e))
        for i in range(DMEM_WORDS): mem[i] = memd.get(i, 0) & 0xFFFFFFFF
        return LaunchResult()


def _parse_tb(log):
    cyc = re.search(r'TB_DONE cycles=(\d+)', log)
    flt = re.search(r'TB_FAULT (.*)', log)
    if 'TB_TIMEOUT' in log: return None, 'hang: DUT never asserted done'
    return (int(cyc.group(1)) if cyc else None), (flt.group(1).strip() if flt else None)


def _write_hex(path, words):
    with open(path, 'w') as f: f.write(''.join(f'{w & 0xFFFFFFFF:08x}\n' for w in words))


def _read_hex(path):
    with open(path) as f: return [int(l, 16) for l in f if l.strip()]


def _sva_files():
    d = os.path.join(RTL_DIR, 'sva')
    chk = [os.path.join(d, f) for f in ('core_sva.sv', 'misc_sva.sv')]
    binds = sorted(os.path.join(d, f) for f in os.listdir(d) if f.startswith('bind_') and f != 'bind_top.sv')
    return chk + binds


class VerilatorBackend:
    """tb_random under Verilator, built once per profile into sw/build/verilator_<profile>/."""
    def __init__(self, profile_name, profile, lat=0, maxcyc=5_000_000, rebuild=False, sva=True):
        from xsim_run import RTL_SOURCES
        self.lat, self.maxcyc = lat, maxcyc
        self.dir = os.path.join(BUILD, f'verilator_{profile_name}')
        self.bin = os.path.join(self.dir, 'rand_tb')
        srcs = [os.path.join(RTL_DIR, s) for s in RTL_SOURCES] + (_sva_files() if sva else []) + [TB_RANDOM]
        newest = max(os.path.getmtime(s) for s in srcs)
        if rebuild or not os.path.exists(self.bin) or os.path.getmtime(self.bin) < newest:
            if not shutil.which('verilator'): raise DeviceError('verilator not found on PATH')
            os.makedirs(self.dir, exist_ok=True)
            defs = ['SYNTHESIS=1', 'MAHI_SIM_CHECKS=1'] + profile.defines
            cmd = (['verilator', '--binary', '--timing', '--assert', '-Wno-fatal', '-Wno-WIDTH', '-Wno-UNOPTFLAT',
                    '-Wno-PINMISSING', '--top-module', 'tb_random', '-Mdir', self.dir, '-o', 'rand_tb',
                    f'-I{os.path.join(RTL_DIR, "include")}'] + [f'-D{d}' for d in defs] + srcs)
            p = subprocess.run(cmd, capture_output=True, text=True)
            if p.returncode != 0 or not os.path.exists(self.bin):
                errs = [l for l in (p.stdout + p.stderr).splitlines() if '%Error' in l][:5]
                raise DeviceError('verilator build failed: ' + ' | '.join(errs or [p.stderr[-1500:]]))

    def run(self, text, mem, threads):
        with tempfile.TemporaryDirectory(prefix='mahi_') as d:
            _write_hex(f'{d}/prog.hex', text); _write_hex(f'{d}/dmem.hex', mem)
            p = subprocess.run([self.bin, f'+prog={d}/prog.hex', f'+dmem={d}/dmem.hex', f'+out={d}/out.hex',
                                f'+lat={self.lat}', f'+threads={threads}', f'+maxcyc={self.maxcyc}', '+verilator+quiet'],
                               capture_output=True, text=True)
            log = p.stdout + p.stderr
            cycles, fault = _parse_tb(log)
            errs = [l for l in log.splitlines() if '%Error' in l or 'SVA' in l]
            if errs and not fault: fault = 'simulation error: ' + errs[0].strip()
            if os.path.exists(f'{d}/out.hex'):
                mem[:] = _read_hex(f'{d}/out.hex')[:DMEM_WORDS]
            elif not fault:
                fault = f'no memory dump (exit code {p.returncode})'
        return LaunchResult(cycles, fault, log[-4000:])


class XsimBackend:
    """tb_random under Vivado xsim (FPGA/sim/xsim_run.py does the tool handling). Snapshot built on first use."""
    def __init__(self, profile_name, profile, lat=0, maxcyc=5_000_000, vivado=None, timeout=3600):
        import xsim_run
        if profile_name not in xsim_run.PROFILE_DEF: raise DeviceError(f'xsim backend supports {list(xsim_run.PROFILE_DEF)}')
        self.x, self.lat = xsim_run, lat
        self.a = types.SimpleNamespace(vivado=vivado, profile=profile_name, define=[], maxcyc=maxcyc, timeout=timeout)
        self.name = 'mahi_rt'
        files = [f'{xsim_run.RTL}/{s}' for s in xsim_run.RTL_SOURCES] + [TB_RANDOM.replace('\\', '/')]
        try:
            self.dir = xsim_run.build(self.a, self.name, 'tb_random', files)
        except xsim_run.BuildError as e:
            raise DeviceError(f'xsim build failed: {e}')

    def run(self, text, mem, threads):
        d = tempfile.mkdtemp(prefix='mahi_', dir=self.dir).replace('\\', '/')
        try:
            _write_hex(f'{d}/prog.hex', text); _write_hex(f'{d}/dmem.hex', mem)
            rc, log = self.x.simulate(self.a, self.dir, self.name,
                                      [f'prog={d}/prog.hex', f'dmem={d}/dmem.hex', f'out={d}/out.hex', f'lat={self.lat}',
                                       f'threads={threads}', f'maxcyc={self.a.maxcyc}'], self.a.timeout, d)
            cycles, fault = _parse_tb(log)
            errs = self.x.sim_errors(log)
            if errs and not fault: fault = 'simulation error: ' + errs[0].strip()
            if os.path.exists(f'{d}/out.hex'): mem[:] = _read_hex(f'{d}/out.hex')[:DMEM_WORDS]
            elif not fault: fault = f'no memory dump (exit code {rc})'
        finally:
            shutil.rmtree(d, ignore_errors=True)
        return LaunchResult(cycles, fault, log[-4000:])
