"""Thread/lane/shared-memory configuration shared by the Python tools (default = full ASIC profile).

`make MINI=1 ...` exports MAHI_THREADS=4 MAHI_LANES=2 MAHI_SHARED=32 for the small physical bring-up profile
(gpu_pkg.sv TARGET_ASIC_MINI). Shared memory is always 8 words per thread: the generator's own-slot and read-out
patterns (tid + N*k, tid*8 + j) rely on that.
"""
import os

THREADS = int(os.environ.get('MAHI_THREADS', '8'))
LANES = int(os.environ.get('MAHI_LANES', '4'))
SHARED = int(os.environ.get('MAHI_SHARED', '64'))
WARPS = THREADS // LANES
LANE_BITS = LANES.bit_length() - 1        # warp id = tid >> LANE_BITS
THREAD_BITS = THREADS.bit_length() - 1    # log2(THREADS)

assert THREADS % LANES == 0 and (LANES & (LANES - 1)) == 0 and (THREADS & (THREADS - 1)) == 0
assert SHARED == 8 * THREADS, f'shared memory must be 8 words/thread (got {SHARED} for {THREADS} threads)'
