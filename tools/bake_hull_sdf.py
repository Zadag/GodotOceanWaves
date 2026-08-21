"""Bakes a top-down signed distance field of the ship hull from model.glb.

Outputs assets/water/hull_sdf.png (8-bit grayscale):
  0.5 = exactly on the hull outline, >0.5 outside, <0.5 inside.
  Encoded range: +/- SDF_RANGE metres, mapped to [0,1].
Also prints the ship-local UV rect so shader uniforms can be configured.
"""
import json
import math
import struct
import zlib

GLB = '/home/kevin/GodotOceanWaves/assets/ship/model.glb'
OUT = '/home/kevin/GodotOceanWaves/assets/water/hull_sdf.png'
DECK_Y = 1.5        # Only geometry at/below this local Y defines the silhouette.
SDF_RANGE = 2.0     # Metres encoded either side of the outline.
GRID_LONG = 256     # Resolution along the hull's longest horizontal axis.


def read_glb(path):
    with open(path, 'rb') as f:
        data = f.read()
    magic, version, length = struct.unpack_from('<III', data, 0)
    assert magic == 0x46546C67
    offset = 12
    gltf = None
    bin_chunk = b''
    while offset < length:
        clen, ctype = struct.unpack_from('<II', data, offset)
        chunk = data[offset + 8:offset + 8 + clen]
        if ctype == 0x4E4F534A:
            gltf = json.loads(chunk)
        elif ctype == 0x004E4942:
            bin_chunk = chunk
        offset += 8 + clen
    return gltf, bin_chunk


COMP = {5120: ('b', 1), 5121: ('B', 1), 5122: ('h', 2), 5123: ('H', 2),
        5125: ('I', 4), 5126: ('f', 4)}
NCOMP = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}


def read_accessor(gltf, bin_chunk, index):
    acc = gltf['accessors'][index]
    view = gltf['bufferViews'][acc['bufferView']]
    start = view.get('byteOffset', 0) + acc.get('byteOffset', 0)
    stride = view.get('byteStride') or NCOMP[acc['type']] * COMP[acc['componentType']][1]
    fmt, size = COMP[acc['componentType']]
    n = NCOMP[acc['type']]
    out = []
    for i in range(acc['count']):
        base = start + i * stride
        out.append(struct.unpack_from('<' + fmt * n, bin_chunk, base))
    return out


def node_matrix(node):
    if 'matrix' in node:
        m = node['matrix']  # column-major
        return [[m[0], m[4], m[8], m[12]],
                [m[1], m[5], m[9], m[13]],
                [m[2], m[6], m[10], m[14]],
                [m[3], m[7], m[11], m[15]]]
    t = node.get('translation', [0, 0, 0])
    r = node.get('rotation', [0, 0, 0, 1])
    s = node.get('scale', [1, 1, 1])
    x, y, z, w = r
    rot = [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]
    return [
        [rot[0][0] * s[0], rot[0][1] * s[1], rot[0][2] * s[2], t[0]],
        [rot[1][0] * s[0], rot[1][1] * s[1], rot[1][2] * s[2], t[1]],
        [rot[2][0] * s[0], rot[2][1] * s[1], rot[2][2] * s[2], t[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]


def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def transform_point(m, p):
    x, y, z = p
    return (m[0][0] * x + m[0][1] * y + m[0][2] * z + m[0][3],
            m[1][0] * x + m[1][1] * y + m[1][2] * z + m[1][3],
            m[2][0] * x + m[2][1] * y + m[2][2] * z + m[2][3])


def collect_tris(gltf, bin_chunk):
    tris = []

    def walk(node_index, parent):
        node = gltf['nodes'][node_index]
        world = mat_mul(parent, node_matrix(node))
        if 'mesh' in node:
            mesh = gltf['meshes'][node['mesh']]
            for prim in mesh['primitives']:
                if prim.get('mode', 4) != 4:
                    continue
                pos = read_accessor(gltf, bin_chunk, prim['attributes']['POSITION'])
                verts = [transform_point(world, p) for p in pos]
                if 'indices' in prim:
                    idx = read_accessor(gltf, bin_chunk, prim['indices'])
                    indices = [int(i[0]) for i in idx]
                else:
                    indices = list(range(len(verts)))
                for k in range(0, len(indices) - 2, 3):
                    tris.append((verts[indices[k]], verts[indices[k + 1]], verts[indices[k + 2]]))
        for child in node.get('children', []):
            walk(child, world)

    scene = gltf['scenes'][gltf.get('scene', 0)]
    identity = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    for root in scene['nodes']:
        walk(root, identity)
    return tris


def main():
    gltf, bin_chunk = read_glb(GLB)
    tris = collect_tris(gltf, bin_chunk)
    print(f'total triangles: {len(tris)}')
    kept = [t for t in tris if min(v[1] for v in t) <= DECK_Y]
    print(f'triangles at/below Y={DECK_Y}: {len(kept)}')

    xs = [v[0] for t in kept for v in t]
    zs = [v[2] for t in kept for v in t]
    pad = 0.25
    x_min, x_max = min(xs) - pad, max(xs) + pad
    z_min, z_max = min(zs) - pad, max(zs) + pad
    span_x, span_z = x_max - x_min, z_max - z_min
    print(f'silhouette bounds: x [{x_min:.3f}, {x_max:.3f}]  z [{z_min:.3f}, {z_max:.3f}]')

    # Square texels: long axis gets GRID_LONG cells.
    if span_z >= span_x:
        H, W = GRID_LONG, max(8, round(GRID_LONG * span_x / span_z))
        u_of = lambda x: (x - x_min) / span_x * W   # image column <- local X
        v_of = lambda z: (z - z_min) / span_z * H   # image row    <- local Z
    else:
        W, H = GRID_LONG, max(8, round(GRID_LONG * span_z / span_x))
        u_of = lambda x: (x - x_min) / span_x * W
        v_of = lambda z: (z - z_min) / span_z * H
    texel_m = span_x / W
    print(f'grid: {W}x{H}, texel ~= {texel_m * 100:.1f} cm')

    grid = bytearray(W * H)

    def fill_tri(p0, p1, p2):
        xs_ = [u_of(v[0]) for v in (p0, p1, p2)]
        ys_ = [v_of(v[2]) for v in (p0, p1, p2)]
        min_i = max(int(math.floor(min(xs_))), 0), max(int(math.floor(min(ys_))), 0)
        max_i = min(int(math.ceil(max(xs_))), W - 1), min(int(math.ceil(max(ys_))), H - 1)
        if min_i[0] > max_i[0] or min_i[1] > max_i[1]:
            return
        ax, ay = xs_[0], ys_[0]
        bx, by = xs_[1], ys_[1]
        cx, cy = xs_[2], ys_[2]
        area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
        if abs(area) < 1e-9:
            return
        sign = 1.0 if area > 0 else -1.0
        for gy in range(min_i[1], max_i[1] + 1):
            for gx in range(min_i[0], max_i[0] + 1):
                px, py = gx + 0.5, gy + 0.5
                e0 = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
                e1 = (cx - bx) * (py - by) - (cy - by) * (px - bx)
                e2 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx)
                if e0 * sign >= 0 and e1 * sign >= 0 and e2 * sign >= 0:
                    grid[gy * W + gx] = 1

    for t in kept:
        fill_tri(*t)

    # Close pinholes: dilate then erode.
    def morph(src, op):
        dst = bytearray(src)
        for gy in range(H):
            for gx in range(W):
                vals = []
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = gy + dy, gx + dx
                        if 0 <= ny < H and 0 <= nx < W:
                            vals.append(src[ny * W + nx])
                dst[gy * W + gx] = max(vals) if op == 'dilate' else min(vals)
        return dst

    closed = morph(morph(grid, 'dilate'), 'erode')
    changed = sum(1 for a, b in zip(grid, closed) if a != b)
    print(f'morphological close fixed {changed} texels')
    grid = closed

    INF = 1e9
    f_inside = [INF] * (W * H)   # distance to nearest inside cell (for outside cells)
    f_outside = [INF] * (W * H)  # distance to nearest outside cell (for inside cells)
    for i, g in enumerate(grid):
        if g:
            f_inside[i] = 0.0
        else:
            f_outside[i] = 0.0

    def chamfer(field):
        for gy in range(H):
            for gx in range(W):
                i = gy * W + gx
                best = field[i]
                for ddx, ddy, cost in ((-1, 0, 3), (1, 0, 3), (0, -1, 3), (0, 1, 3), (-1, -1, 4), (1, -1, 4), (-1, 1, 4), (1, 1, 4)):
                    nx_, ny_ = gx + ddx, gy + ddy
                    if 0 <= nx_ < W and 0 <= ny_ < H:
                        best = min(best, field[ny_ * W + nx_] + cost)
                field[i] = best
        for gy in range(H - 1, -1, -1):
            for gx in range(W - 1, -1, -1):
                i = gy * W + gx
                best = field[i]
                for ddx, ddy, cost in ((-1, 0, 3), (1, 0, 3), (0, -1, 3), (0, 1, 3), (-1, -1, 4), (1, -1, 4), (-1, 1, 4), (1, 1, 4)):
                    nx_, ny_ = gx + ddx, gy + ddy
                    if 0 <= nx_ < W and 0 <= ny_ < H:
                        best = min(best, field[ny_ * W + nx_] + cost)
                field[i] = best

    chamfer(f_inside)
    chamfer(f_outside)

    px = bytes()
    rows = []
    for gy in range(H):
        row = bytearray([0])
        for gx in range(W):
            i = gy * W + gx
            # Outside cells have distance-to-inside > 0 -> positive SDF (brighter).
            sdf_m = ((f_inside[i] - f_outside[i]) / 3.0) * texel_m
            sdf_m = max(-SDF_RANGE, min(SDF_RANGE, sdf_m))
            row.append(int(round(127.5 + 127.5 * (sdf_m / SDF_RANGE))))
        rows.append(bytes(row))

    raw = b''.join(rows)

    def chunk(tag, payload):
        c = struct.pack('>I', len(payload)) + tag + payload
        return c + struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF)

    ihdr = struct.pack('>IIBBBBB', W, H, 8, 0, 0, 0, 0)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

    with open(OUT, 'wb') as f:
        f.write(png)
    print(f'wrote {OUT} ({W}x{H})')
    print('UNIFORMS:')
    print(f'  hull_uv_rect = Vector4({x_min:.4f}, {z_min:.4f}, {1.0 / span_x:.6f}, {1.0 / span_z:.6f})')
    print(f'  sdf_range = {SDF_RANGE}')


if __name__ == '__main__':
    main()
