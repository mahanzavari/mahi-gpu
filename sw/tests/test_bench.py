"""Benchmark suite (sw/bench): every case is correct on the golden model; on the RTL perf build the probes are
consistent with the golden model's architectural counts and the issue-slot buckets partition the cycles.

  python sw/tests/test_bench.py          (RTL tests need verilator; MAHI_PROFILE as in test_kernels.py)
"""
import os, shutil, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..')); sys.path.insert(0, os.path.join(HERE, '..', 'bench'))
import numpy as np
from mahi import Device
from cases import CASES, BY_NAME
from metrics import derive, BUCKETS

PROFILE = os.environ.get('MAHI_PROFILE', 'fpga')
HAVE_RTL = bool(shutil.which('verilator'))


def golden(c):
    return Device('golden', PROFILE, heap_base=64, mem_words=c.mem_words, count=True)


def rtl(c):
    return Device('verilator', PROFILE, heap_base=64, mem_words=c.mem_words, perf=True)


class Golden(unittest.TestCase):
    def test_every_case_matches_numpy(self):
        for c in CASES:
            d = golden(c)
            if c.supported(d.profile): continue
            with self.subTest(c.name):
                r, _ = c.run(d)                       # raises on a NumPy mismatch
                self.assertGreater(r.counts['thread_instr'], 0)


@unittest.skipUnless(HAVE_RTL, 'verilator not installed')
class Probes(unittest.TestCase):
    def measure(self, name):
        c = BY_NAME[name]; g = golden(c)
        if c.supported(g.profile): self.skipTest(c.supported(g.profile))
        gr, gout = c.run(g)
        r, out = c.run(rtl(c))
        self.assertTrue(np.array_equal(out, gout), f'{name}: RTL output differs from golden')
        return derive(c, gr.counts, r.perf, r.cycles, g.profile), gr.counts

    def test_invariants(self):
        for name in ('vadd', 'stride_s4', 'smem_s4', 'fma_chain8', 'chase_l1', 'reduce_sum', 'diverge_m3'):
            with self.subTest(name):
                m, k = self.measure(name)
                self.assertAlmostEqual(sum(m['b_' + b] for b in BUCKETS), 1.0, places=9)   # buckets partition cycles
                self.assertTrue(m['instr_match'], 'RTL thread-instructions != golden dynamic count')
                self.assertEqual(m['lsu_req_rd'], k['warp_ld'], 'one LSU read request per warp load')
                self.assertEqual(m['lsu_req_wr'], k['warp_st'], 'one LSU write request per warp store')

    def test_coalescing_counts(self):
        for name, want in (('stride_s1', 1.0), ('stride_s2', None), ('stride_s4', None)):
            m, k = self.measure(name)
            self.assertAlmostEqual(m['tx_per_ld'], m['ideal_tx_per_ld'], places=9)    # one transaction per line touched
            if want: self.assertEqual(m['tx_per_ld'], want)

    def test_simd_efficiency(self):
        m, _ = self.measure('diverge_m0'); self.assertEqual(m['simd_eff'], 1.0)
        m, _ = self.measure('diverge_m3'); self.assertLess(m['simd_eff'], 0.5)

    @unittest.expectedFailure
    def test_atomics_coherent_across_cores(self):
        """known RTL limitation (sw/bench report, "Atomics are not coherent across cores"): fix the RTL, then drop
        expectedFailure"""
        c = BY_NAME['atomic_b1']
        if c.supported(golden(c).profile) or golden(c).profile.cores < 2: self.skipTest('needs 2 cores')
        c.run(rtl(c))


if __name__ == '__main__':
    print('profile:', PROFILE, 'rtl:', HAVE_RTL)
    unittest.main(verbosity=2)
