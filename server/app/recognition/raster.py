from PIL import Image, ImageDraw


def tight_bbox(strokes):
    """返回笔迹外接框 (minx, miny, maxx, maxy)，归一化坐标；无笔迹返回 None。"""
    pts = [p for stroke in strokes for p in stroke if stroke]
    if not pts:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def rasterize(strokes, size=224, stroke_width=8, pad=24, supersample=4):
    """把归一化笔迹栅格化成白底黑字灰度图（单字）。

    - 按外接框裁剪：让字填满画面
    - 细笔画 + 大留白：更接近印刷体模型训练分布（实测置信度显著提高）
    - 超采样后降采样：笔画带抗锯齿，边缘更平滑
    strokes: list[list[[x, y, t]]]，x/y 在 [0,1]，t 时间戳不用。
    """
    ss = max(1, int(supersample))
    big = size * ss
    img = Image.new("L", (big, big), 255)
    draw = ImageDraw.Draw(img)
    bbox = tight_bbox(strokes)
    if bbox is None:
        return img.resize((size, size), Image.LANCZOS)
    minx, miny, maxx, maxy = bbox
    bw = max(maxx - minx, 1e-6)
    bh = max(maxy - miny, 1e-6)
    pad_big = pad * ss
    scale = (big - 2 * pad_big) / max(bw, bh)
    w = bw * scale
    h = bh * scale
    ox = (big - w) / 2
    oy = (big - h) / 2
    width_big = max(1, int(round(stroke_width * ss)))
    for stroke in strokes:
        if not stroke:
            continue
        pts = [
            (ox + (p[0] - minx) * scale, oy + (p[1] - miny) * scale)
            for p in stroke
        ]
        if len(pts) == 1:
            r = width_big / 2
            x, y = pts[0]
            draw.ellipse([x - r, y - r, x + r, y + r], fill=0)
        else:
            draw.line(pts, fill=0, width=width_big, joint="curve")
    return img.resize((size, size), Image.LANCZOS)
