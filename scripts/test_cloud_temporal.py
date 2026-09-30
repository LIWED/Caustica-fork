"""Compile and execute production Slang cloud math; no GPU or Minecraft needed."""
import ctypes
import math
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "cloud-temporal-tests"
OUT.mkdir(parents=True, exist_ok=True)
SDK = Path(os.environ["VULKAN_SDK"])
CPP = OUT / "cloud-test.cpp"
DLL = OUT / "cloud-test.dll"
CPP.unlink(missing_ok=True)
DLL.unlink(missing_ok=True)
# Compile in one module to test private helpers without changing their visibility.
source = (ROOT / "shaders/world/cloud_volume.slang").read_text(encoding="utf-8")
if "--legacy" in sys.argv:
    # Reproduce the pre-fix equations in memory; never modify the checked-out shader.
    source = re.sub(r"float detailWeight = .*?;", "float detailWeight = 1.0;", source)
    source = re.sub(r"float edgeHalfWidth = .*?;", "float edgeHalfWidth = 0.08;", source)
    source = re.sub(r"if \(body \+ maxDetail.*?return 0\.0;",
                    "if (body < threshold - 0.13) return 0.0;", source)
    source = re.sub(r"float elevation = sqrt\(.*?float2 offset = stableDir\.xz \* t;",
                    "float t = heightDelta / stableDir.y;\n"
                    "        float2 offset = stableDir.xz * t;\n"
                    "        float reach = length(offset);\n"
                    "        if (reach > 4000.0) offset *= 4000.0 / reach;",
                    source, flags=re.DOTALL)
test = (ROOT / "src/test/slang/cloud_temporal_test.slang").read_text(encoding="utf-8")
# Independent oracle: evaluate the same density without any coarse early-out.
start = source.index("float cloudLayerDensity(")
end = source.index("// Ray/slab intersection", start)
reference = source[start:end].replace("cloudLayerDensity(", "cloudLayerDensityReference(", 1)
reference = re.sub(r"^\s*if \(body.*return 0\.0;\s*$", "", reference, flags=re.MULTILINE)
harness = OUT / "cloud-test.slang"
harness.write_text(source.replace("module cloud_volume;", "") + "\n" + reference + "\n" +
                   test.replace("import cloud_volume;", "").replace("import world_common;", ""),
                   encoding="utf-8")
subprocess.run([str(SDK / "Bin/slangc.exe"), str(harness),
                "-I", str(ROOT / "shaders/world"), "-target", "cpp", "-o", str(CPP)], check=True)
subprocess.run(["D:/program/mingw64/bin/g++.exe", "-std=c++17", "-O2", "-shared",
                "-static-libgcc", "-static-libstdc++", str(CPP), "-o", str(DLL)], check=True)


class Float4(ctypes.Structure):
    _fields_ = [(name, ctypes.c_float) for name in ("x", "y", "z", "w")]


class Dispatch(ctypes.Structure):
    _fields_ = [("start", ctypes.c_uint32 * 3), ("end", ctypes.c_uint32 * 3)]


class Globals(ctypes.Structure):
    _fields_ = [("data", ctypes.POINTER(Float4)), ("count", ctypes.c_size_t)]


count = 16384 * 32
values = (Float4 * count)()
globals_ = Globals(values, count)
dispatch = Dispatch((0, 0, 0), (count, 1, 1))
library = ctypes.CDLL(str(DLL))
entry = library.cloudTemporalTests
entry.argtypes = [ctypes.POINTER(Dispatch), ctypes.c_void_p, ctypes.POINTER(Globals)]
entry.restype = None
entry(ctypes.byref(dispatch), None, ctypes.byref(globals_))
density_error = max(abs(v.x - v.y) for v in values)
shadow_jump = max(abs(v.z - v.w) for v in values)
finite = all(math.isfinite(a) and 0 <= a <= 1 for v in values for a in (v.x, v.y, v.z, v.w))
print(f"{count} production samples: density early-out error = {density_error:.7f}; "
      f"shadow delta / 60 Hz frame = {shadow_jump:.7f}; finite/bounded = {finite}")
for band in (0, 3, 6, 12, 20, 31):
    block = values[band * 16384:(band + 1) * 16384]
    print(f"  sinY={0.005 + band * (0.245 / 31):.4f}: max shadow delta "
          f"{max(abs(v.z-v.w) for v in block):.7f}")
assert finite, "cloud output must be finite and in [0,1]"
assert density_error < 0.000001, "coarse early-out discards visible cloud density"
assert shadow_jump < 0.04, "60 Hz shadow transmittance change exceeds four percentage points"
# Reuse the same production module to exercise invariants separately.
invariants = library.cloudInvariantTests
invariants.argtypes = entry.argtypes
invariants.restype = None
dispatch = Dispatch((0, 0, 0), (64, 1, 1))
invariants(ctypes.byref(dispatch), None, ctypes.byref(globals_))
for v in values[:64]:
    assert abs(v.x - 1) < 1e-6, "disabled clouds must transmit all light"
    assert abs(v.y - 1) < 1e-6, "a surface above both decks must not receive cloud shadow"
    assert abs(v.z) < 1e-5, "frame/camera/rebase changed world-space cloud shadows"
    assert abs(v.w) < 1e-6, "jittered NEE direction changed cloud shadow"
print("PASS: disabled clouds, above-deck surfaces, frame/camera/rebase invariance, NEE jitter invariance")
