from PIL import Image, ImageDraw


def tight_bbox(strokes):
    """返回笔迹外接框 (minx, miny, maxx, maxy)，归一化坐标；无笔迹返回 None。"""
    pts = [p for stroke in strokes for p in stroke if stroke]
    if not pts:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def rasterize(strokes, size=224, stroke_width=10, pad=16):
    """把归一化笔迹按外接框裁剪后栅格化成白底黑字灰度图（单字）。

    裁剪让字填满画面、改善识别输入；尺寸对精度几乎无影响（识别模型内部会缩放）。
    strokes: list[list[[x, y, t]]]，x/y 在 [0,1]，t 时间戳不用。
    """
    img = Image.new("L", (size, size), 255)
    draw = ImageDraw.Draw(img)
    bbox = tight_bbox(strokes)
    if bbox is None:
        return img
    minx, miny, maxx, maxy = bbox
    bw = max(maxx - minx, 1e-6)
    bh = max(maxy - miny, 1e-6)
    scale = (size - 2 * pad) / max(bw, bh)
    w = bw * scale
    h = bh * scale
    ox = (size - w) / 2
    oy = (size - h) / 2
    for stroke in strokes:
        if not stroke:
            continue
        pts = [
            (ox + (p[0] - minx) * scale, oy + (p[1] - miny) * scale)
            for p in stroke
        ]
        if len(pts) == 1:
            r = stroke_width / 2
            x, y = pts[0]
            draw.ellipse([x - r, y - r, x + r, y + r], fill=0)
        else:
            draw.line(pts, fill=0, width=stroke_width, joint="curve")
    return img
