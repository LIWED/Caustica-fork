"""Run the actual Slang POM solver on the CPU through Slang's C++ target.

Requires slangc (Vulkan SDK), a C++17 compiler and Python; no game or GPU required.
Example: python scripts/test_parallax.py --cxx D:/program/mingw64/bin/g++.exe
"""
import argparse
import ctypes
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slangc")
    parser.add_argument("--cxx", default=shutil.which("g++"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    sdk = os.environ.get("VULKAN_SDK")
    slangc = args.slangc or (str(Path(sdk) / "Bin" / "slangc.exe") if sdk else shutil.which("slangc"))
    if not slangc or not args.cxx:
        parser.error("Set VULKAN_SDK/--slangc and provide a C++17 compiler via --cxx")
    output = root / "build" / "parallax-tests"
    output.mkdir(parents=True, exist_ok=True)
    cpp = output / "parallax-test.cpp"
    library = output / ("parallax-test.dll" if os.name == "nt" else "parallax-test.so")
    # Never accidentally execute a stale binary after a compiler error.
    cpp.unlink(missing_ok=True)
    library.unlink(missing_ok=True)
    subprocess.run([slangc, str(root / "src/test/slang/parallax_test.slang"),
                    "-I", str(root / "shaders/world"), "-target", "cpp", "-o", str(cpp)], check=True)
    flags = ["-std=c++17", "-O2", "-shared"]
    flags += ["-static-libgcc", "-static-libstdc++"] if os.name == "nt" else ["-fPIC"]
    subprocess.run([args.cxx, *flags, str(cpp), "-o", str(library)], check=True)

    class Float2(ctypes.Structure):
        _fields_ = [("x", ctypes.c_float), ("y", ctypes.c_float)]

    class Dispatch(ctypes.Structure):
        _fields_ = [("start", ctypes.c_uint32 * 3), ("end", ctypes.c_uint32 * 3)]

    class Globals(ctypes.Structure):
        _fields_ = [("data", ctypes.POINTER(Float2)), ("count", ctypes.c_size_t)]

    # Literal answers derived from plane intersections, independently of the solver.
    cases = [
        ("white height preserves UV", (0.5, 0.5)),
        ("black height reaches bottom", (0.3, 0.5)),
        ("half height", (0.4, 0.5)),
        ("linear ramp intersection", (0.375, 0.5)),
        ("first occluding step", (0.42, 0.5)),
        ("unit UV ray", (-0.25, 0.0)),
        ("mirrored UV winding", (0.25, 0.0)),
        ("rotated UV axes", (0.0, -0.25)),
        ("zero strength", (0.0, 0.0)),
        ("degenerate UV triangle", (0.0, 0.0)),
        ("degenerate geometry", (0.0, 0.0)),
        ("distant mip fallback", (0.0, 0.0)),
        ("grazing fallback", (0.0, 0.0)),
        ("uniform scale invariance", (-0.25, 0.0)),
        ("normal incidence", (0.0, 0.0)),
        ("tile wrapping and bilinear inset", (0.96875, 0.03125)),
        ("single texel footprint", (0.5, 0.5)),
        ("minimum step budget", (0.375, 0.5)),
        ("maximum step budget", (0.375, 0.5)),
        ("double depth", (-0.5, 0.0)),
        ("nonuniform geometry scale", (-0.125, 0.0)),
        ("skewed triangle", (-0.25, 0.0)),
        ("trilinear upper mip stays in tile", (0.125, 0.0625)),
        ("ridge blocks direct light inside a groove", (0.0, 0.0)),
        ("flat groove does not self-shadow", (1.0, 0.0)),
        ("ridge behind the light does not shadow", (1.0, 0.0)),
        ("top surface does not self-shadow", (1.0, 0.0)),
        ("low sunlight still traverses the height field", (-0.5, 0.0)),
        ("height ramp tilts the visible normal", (-0.2425356, 0.9701425)),
        ("height cliff faces outward instead of lying flat", (0.99920096, 0.03996804)),
        ("flat height retains the geometric normal", (0.0, 1.0)),
        ("nearby 128-texel ray gets subtexel steps", (96.0, 0.0)),
        ("sampling budget remains bounded", (128.0, 0.0)),
        ("mirrored UV reverses the world-space slope", (0.2425356, 0.9701425)),
        ("rotated UV keeps the wall normal aligned", (-0.2425356, 0.9701425)),
    ]
    values = (Float2 * len(cases))(*[Float2(float("nan"), float("nan")) for _ in cases])
    globals_ = Globals(values, len(cases))
    dispatch = Dispatch((0, 0, 0), (len(cases), 1, 1))
    dll = ctypes.CDLL(str(library))
    entry = dll.parallaxTests
    entry.argtypes = [ctypes.POINTER(Dispatch), ctypes.c_void_p, ctypes.POINTER(Globals)]
    entry.restype = None
    entry(ctypes.byref(dispatch), None, ctypes.byref(globals_))
    for (name, expected), actual in zip(cases, values):
        tolerance = 0.0004 if name == "first occluding step" else 0.00001
        if not all(math.isfinite(a) and abs(a - e) <= tolerance
                   for a, e in zip((actual.x, actual.y), expected)):
            raise AssertionError(f"{name}: expected {expected}, got {(actual.x, actual.y)}")
        print(f"PASS: {name}")
    print(f"{len(cases)} production Slang behavioral checks passed")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
