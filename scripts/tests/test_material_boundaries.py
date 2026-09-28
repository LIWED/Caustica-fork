"""Production-expression boundary probes; no GPU/scene convergence claim."""
import ast
import pathlib
import re
import struct
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HIT = (ROOT / 'shaders/world/world.rchit.slang').read_text(encoding='utf-8')
GEN = (ROOT / 'shaders/world/world.rgen.slang').read_text(encoding='utf-8')
COMMON = (ROOT / 'shaders/world/world_common.slang').read_text(encoding='utf-8')
HIT = re.sub(r'//[^\n]*|/\*.*?\*/', '', HIT, flags=re.S)
GEN = re.sub(r'//[^\n]*|/\*.*?\*/', '', GEN, flags=re.S)


def one(pattern, text):
    matches = re.findall(pattern, text, re.S)
    assert len(matches) == 1, (pattern, len(matches))
    return matches[0]


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def half(x):
    return struct.unpack('e', struct.pack('e', x))[0]


def expression(source, **values):
    """Evaluate only the arithmetic/boolean subset extracted from shader source."""
    tree = ast.parse(source.replace('&&', ' and ').strip(), mode='eval')

    def visit(node):
        if isinstance(node, ast.Constant):
            return f32(node.value)
        if isinstance(node, ast.Name):
            return f32(values[node.id])
        if isinstance(node, ast.BinOp):
            a, b = visit(node.left), visit(node.right)
            if isinstance(node.op, ast.Sub): return f32(a - b)
            if isinstance(node.op, ast.Mult): return f32(a * b)
        if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.And):
            return all(visit(v) for v in node.values)
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            a, b = visit(node.left), visit(node.comparators[0])
            if isinstance(node.ops[0], ast.Gt): return a > b
            if isinstance(node.ops[0], ast.LtE): return a <= b
        raise AssertionError('Unsupported production syntax: ' + ast.dump(node))
    return visit(tree.body)


DECODE = one(r'void decodeSpec\([^\{]+\{\s*rough\s*=\s*([^;]+);', HIT).replace('s.r', 'smooth')
GATE = one(r'if\s*\(([^()]+)\)\s*\{\s*n = perturbNormal\(n, tp0, tp1, tp2', HIT)
GATE = GATE.replace('pr.mat.w', 'flag').replace('pr.tint.w', 'bucket')
MIN_ROUGH = float(one(r'static const float MIN_ROUGH\s*=\s*([\d.]+);', GEN))
ALPHAS = [one(r'float(?:3)? ' + name + r'\([^\{]+\{.*?float a\s*=\s*([^;]+);', GEN)
          for name in ['ggxD', 'ggxG1', 'sampleGGXVNDF']]


class MaterialBoundaries(unittest.TestCase):
    def test_offline_glass_lod_trace_setter(self):
        def contract(gen):
            setter = one(r'void payloadSetTraceState\([^\{]+\{(.*?)\n\}', gen)
            self.assertRegex(setter, r'#ifdef CAUSTICA_OFFLINE_FP32\s+payload.flags \|= PAYLOAD_OFFLINE_GLASS_LOD0;\s+#endif')
            self.assertIn('payload.flags = showCelestial ? PAYLOAD_SHOW_CELESTIAL : 0u;', setter)
            calls = list(re.finditer(r'(?<!void )traceRadianceReordered\(', gen))
            self.assertEqual(len(calls), 5)  # includes the bounded offline interface pilot
            for call in calls:
                reset = gen.rfind('payload.hitT = -1.0;', 0, call.start())
                self.assertGreaterEqual(reset, 0)
                self.assertIn('payloadSetTraceState(', gen[reset:call.start()],
                              'every real radiance trace must seed its trace-only flag')
        contract(GEN)
        with self.assertRaises(AssertionError):
            contract(GEN.replace('payload.flags |= PAYLOAD_OFFLINE_GLASS_LOD0;', ''))

    def test_offline_glass_lod_consumer(self):
        def contract(hit):
            main = hit[hit.index('void main('):]
            condition = one(r'float4 gtex = blockAtlas.SampleLevel\(uv,\s*([^;]+)\);', main)
            self.assertEqual(condition.replace(' ', ''), 'offlineGlassLod0?0.0:blockLod',
                             'glass tint must select fixed LOD only from the trace flag')
            cached = 'bool offlineGlassLod0 = (payload.flags & PAYLOAD_OFFLINE_GLASS_LOD0) != 0u;'
            self.assertIn(cached, main)
            first_write = min(main.index('payload.staticLightIndex ='), main.index('payloadSetPacked('))
            self.assertLess(main.index(cached), first_write, 'cache trace-only flag before overwriting hit payload')
            self.assertIn('offlineGlassLod0 ? packHalf2(float2(0.0, 0.0)) : rayCone,', main,
                          'glass breaking tint must use the same offline fixed footprint')
        contract(HIT)
        with self.assertRaises(AssertionError):
            contract(HIT.replace('offlineGlassLod0 ? 0.0 : blockLod', 'blockLod'))
        with self.assertRaises(AssertionError):
            contract(HIT.replace('payload.flags & PAYLOAD_OFFLINE_GLASS_LOD0', 'payload.flags & PAYLOAD_SHOW_CELESTIAL'))
        self.assertIn('public static const uint PAYLOAD_OFFLINE_GLASS_LOD0 = 16u;', COMMON)
        self.assertIn('payload.flags = material;', HIT)  # flag is trace-only; no ABI/output material changes
        payload_fields = one(r'public struct Payload \{(.*?)\n\};', COMMON)
        self.assertEqual(len(re.findall(r'public\s+\w+\s+\w+\s*;', payload_fields)), 11)

    def test_perceptual_payload_and_ggx_alpha(self):
        # LabPBR alpha=(1-s)^2; the payload stores perceptual roughness.
        for smooth in [0, .25, .5, .75, .9, 254 / 255, 1]:
            with self.subTest(smooth=smooth):
                got = expression(DECODE, smooth=smooth)
                expected = f32(1 - f32(smooth))
                self.assertAlmostEqual(got, expected, delta=1e-7)
                packed = half(got)
                rough = min(1, max(MIN_ROUGH, packed))
                target = max(MIN_ROUGH, half(expected)) ** 2
                for alpha_expression in ALPHAS:
                    self.assertAlmostEqual(expression(alpha_expression, rough=rough), target, delta=1e-7)

    def test_normal_gate_does_not_interpret_translucent_alpha_as_flag(self):
        for bucket in [0, 1, 1.5, 1.5001, 2]:
            for flag in [0, .4999, .5, .5001, .75, 1]:
                with self.subTest(bucket=bucket, alpha_or_flag=flag):
                    self.assertEqual(expression(GATE, bucket=bucket, flag=flag),
                                     bucket <= 1.5 and flag > .5)

    def test_actual_consumer_and_default_contracts(self):
        # Guards connecting numeric probes to payload packing and production consumers.
        self.assertIn('packHalf2(float2(roughness, metalness))', HIT)
        self.assertIn('unpackHalf2(payload.roughMetal).x', GEN)
        self.assertIn('clamp(payloadRoughness(), MIN_ROUGH, 1.0)', GEN)
        self.assertGreaterEqual(GEN.count('float a = rough * rough;'), 3)
        self.assertEqual(HIT.count('float rough = pr.mat.x;'), 2)
        self.assertEqual(HIT.count('decodeSpec('), 4)  # definition + terrain + two entity sources
        # Entity flags encode texture source 0/1/2, independently of terrain's bucket encoding.
        self.assertRegex(HIT, r'if \(pr.mat.w > 1.5\)\s*\{\s*n = perturbNormal\(n, ep0')
        self.assertRegex(HIT, r'else if \(pr.mat.w > 0.5\)\s*\{\s*n = perturbNormal\(n, ep0')
        for default in [.045, .2, .5, 1]:
            self.assertAlmostEqual(half(default) ** 2, default ** 2, delta=.0003)


if __name__ == '__main__':
    unittest.main(verbosity=2)
