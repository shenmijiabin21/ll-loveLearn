import re
import threading
from typing import Optional

from PIL import ImageFilter

from .raster import rasterize

_HAN = re.compile(r"^[\u4e00-\u9fff]$")


def is_han(text: str) -> bool:
    return bool(_HAN.match(text))


class Recognizer:
    """单字手写识别（RapidOCR / PP-OCR 识别网络，onnxruntime）。

    要点（均以真实学生笔迹实测得出）：
    1. 关掉文字检测、只跑识别网络：整格图会被检测判成"没有文字"而返回空。
    2. 细笔画 + 大留白 + 超采样：更接近印刷体训练分布，置信度明显提高。
    3. 候选字约束：练习只涉及少数几个字，把解码限制在这几个字内，
       模型的判别力显著提升，并能给出"领先幅度"作为可靠性信号。

    约束解码无信号时回退开集识别；两者都不确定则返回 pending，
    由家长人工订正兜底。
    """

    def __init__(
        self,
        min_conf: float = 0.5,
        min_conf_wrong: float = 0.75,
        verdict_mode: str = "conservative",
        margin_min: float = 0.04,
    ):
        self.min_conf = min_conf
        self.min_conf_wrong = min_conf_wrong
        self.verdict_mode = verdict_mode
        self.margin_min = margin_min
        self._engine = None
        self._rec = None
        self._charset = None
        self._failed = False
        self._lock = threading.Lock()

    # —— 模型加载 ——
    def _load(self):
        if self._engine is not None or self._failed:
            return self._engine
        with self._lock:
            if self._engine is not None or self._failed:
                return self._engine
            try:
                from rapidocr_onnxruntime import RapidOCR

                self._engine = RapidOCR()
                try:
                    self._rec = self._engine.text_rec
                    chars = self._rec.postprocess_op.character
                    index: dict[str, int] = {}
                    for i, c in enumerate(chars):
                        index.setdefault(c, i)
                    self._charset = (chars, index)
                except Exception:
                    self._rec = None
                    self._charset = None
            except Exception:
                self._failed = True
                self._engine = None
        return self._engine

    # —— 渲染 ——
    @staticmethod
    def _variants(strokes):
        base = rasterize(strokes)
        variants = [base]
        try:
            variants.append(base.filter(ImageFilter.GaussianBlur(1.2)))
        except Exception:
            pass
        return variants

    # —— 开集识别 ——
    @staticmethod
    def _infer(engine, image):
        import numpy as np

        arr = np.array(image.convert("L"))
        arr = np.stack([arr, arr, arr], axis=-1)
        try:
            out, _ = engine(arr, use_det=False, use_cls=False, use_rec=True)
        except Exception:
            return []
        items = []
        for line in out or []:
            try:
                text = str(line[0]).strip()
                score = float(line[1])
            except Exception:
                continue
            if text:
                items.append((text, score))
        return items

    def recognize(self, strokes):
        engine = self._load()
        if engine is None:
            return []
        best: dict[str, float] = {}
        for variant in self._variants(strokes):
            for text, score in self._infer(engine, variant):
                if best.get(text, 0.0) < score:
                    best[text] = score
        return sorted(best.items(), key=lambda kv: kv[1], reverse=True)

    # —— 候选字约束解码 ——
    def _timestep_probs(self, image):
        import numpy as np

        rec = self._rec
        arr = np.array(image.convert("RGB"))
        norm = rec.resize_norm_img(arr, arr.shape[1] / max(arr.shape[0], 1))
        x = norm if norm.ndim == 4 else norm[None, ...]
        out = np.asarray(rec.session(x), dtype=np.float32)
        while out.ndim > 2:
            out = out[0]
        if out.ndim == 1:
            out = out[None, :]
        shifted = out - out.max(axis=1, keepdims=True)
        exp = np.exp(shifted)
        return exp / exp.sum(axis=1, keepdims=True)

    def _constrained(self, expected: str, strokes, allowed: list[str]):
        """在候选字集合内解码。返回 (排名列表, 领先幅度) 或 None。"""
        self._load()
        if self._rec is None or self._charset is None:
            return None
        chars, index = self._charset
        candidates = [c for c in dict.fromkeys(allowed) if c in index]
        if len(candidates) < 2:
            return None
        import numpy as np

        image = rasterize(strokes, supersample=4)
        probs = self._timestep_probs(image)
        cols = [index[c] for c in candidates]
        sub = probs[:, cols]
        mass = sub.sum(axis=1)
        step = int(np.argmax(mass))
        if mass[step] <= 0:
            return None
        q = sub[step] / mass[step]
        order = np.argsort(q)[::-1]
        ranked = [(candidates[int(order[k])], float(q[order[k]])) for k in range(len(order))]
        margin = ranked[0][1] - (ranked[1][1] if len(ranked) > 1 else 0.0)
        return ranked, margin

    # —— 判定 ——
    def classify(self, expected: str, strokes, allowed: Optional[list[str]] = None):
        """返回 {'verdict': correct|wrong|pending, 'candidates': [str]}。"""
        if not strokes:
            return {"verdict": "blank", "candidates": []}

        # 1) 候选字约束：有足够领先幅度才采纳
        if allowed:
            constrained = self._constrained(expected, strokes, allowed)
            if constrained is not None:
                ranked, margin = constrained
                labels = [c for c, _ in ranked[:5]]
                top, p = ranked[0]
                if top == expected and margin >= self.margin_min:
                    return {"verdict": "correct", "candidates": labels}
                if (
                    self.verdict_mode == "standard"
                    and top != expected
                    and margin >= self.margin_min
                    and p >= 0.3
                ):
                    return {"verdict": "wrong", "candidates": labels}

        # 2) 回退：开集识别
        found = self.recognize(strokes)
        if not found:
            return {"verdict": "pending", "candidates": []}
        labels = [t for t, _ in found[:5]]
        top_text, top_conf = found[0]
        verdict = "pending"
        if is_han(top_text) and top_conf >= self.min_conf:
            if top_text == expected:
                verdict = "correct"
            elif (
                self.verdict_mode == "standard"
                and top_conf >= self.min_conf_wrong
            ):
                verdict = "wrong"
        return {"verdict": verdict, "candidates": labels}


_recognizer: Optional[Recognizer] = None
_recognizer_lock = threading.Lock()


def get_recognizer() -> Recognizer:
    global _recognizer
    if _recognizer is None:
        with _recognizer_lock:
            if _recognizer is None:
                from ..config import settings

                _recognizer = Recognizer(
                    min_conf=settings.min_conf,
                    verdict_mode=settings.verdict_mode,
                )
    return _recognizer
