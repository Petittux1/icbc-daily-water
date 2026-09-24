#!/usr/bin/env python3
# px.py - 设备校准辅助工具: 读一张 PNG 截图, 输出指定像素点的 RGB 值
# 用途: 按 README 的"校准"章节, 用 adb 截图后取色, 填回 water.sh 的坐标区
# 用法: python3 px.py <截图.png> <x,y> [x,y ...]
# 例:   python3 px.py screen.png 216,778 518,780 746,748
import zlib, struct, sys

def parse_png(path):
    data = open(path, 'rb').read()
    pos = 8; w = h = bd = ct = None; idat = b''
    while pos < len(data):
        ln = struct.unpack('>I', data[pos:pos+4])[0]
        typ = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+ln]
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', chunk[:10])
        elif typ == b'IDAT':
            idat += chunk
        elif typ == b'IEND':
            break
        pos += 12 + ln
    return w, h, bd, ct, zlib.decompress(idat)

def unfilter(w, h, bpp, raw):
    stride = w * bpp; out = bytearray(); prev = bytearray(stride); rp = 0
    for y in range(h):
        ft = raw[rp]; rp += 1
        line = bytearray(raw[rp:rp+stride]); rp += stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x-bpp] if x >= bpp else 0
            if ft == 1: line[x] = (line[x] + a) & 0xff
            elif ft == 2: line[x] = (line[x] + b) & 0xff
            elif ft == 3: line[x] = (line[x] + ((a + b) >> 1)) & 0xff
            elif ft == 4:
                p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xff
        out += line; prev = line
    return out

def probe(path, pts):
    w, h, bd, ct, raw = parse_png(path)
    bpp = 3 if ct == 2 else 4
    px = unfilter(w, h, bpp, raw)
    print(f'{path} {w}x{h}')
    for (x, y) in pts:
        if not (0 <= x < w and 0 <= y < h):
            print(f'({x},{y}) out of range'); continue
        o = (y * w + x) * bpp
        r, g, b = px[o], px[o+1], px[o+2]
        L = (r+g+b)//3
        mx = max(r, g, b); mn = min(r, g, b)
        print(f'({x},{y}) RGB=({r},{g},{b}) L={L} sat={mx-mn}')

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    pts = []
    for a in sys.argv[2:]:
        x, y = a.split(',')
        pts.append((int(x), int(y)))
    probe(sys.argv[1], pts)