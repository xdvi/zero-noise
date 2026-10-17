import subprocess, time, os, sys
binp = sys.argv[1] if len(sys.argv) > 1 else "./zig-out/bin/zero-noise"
cmds = [
    ["audit", "src"],
    ["complexity", "src", "--threshold=100"],
    ["blast", "executeSafeRefactor", "--root=src"],
]
for cmd in cmds:
    full = [binp] + cmd
    t0 = time.perf_counter()
    p = subprocess.Popen(full, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    peak = 0
    while p.poll() is None:
        try:
            with open(f"/proc/{p.pid}/statm") as f:
                rss_pages = int(f.read().split()[1])
            peak = max(peak, rss_pages * 4)  # KB on linux (page 4KB)
        except FileNotFoundError:
            pass
        time.sleep(0.005)
    dt = time.perf_counter() - t0
    print(f"{' '.join(cmd)}: elapsed={dt:.3f}s peakrss={peak}KB rc={p.returncode}")
