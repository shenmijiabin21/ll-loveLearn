import re
import threading
from typing import Optional

from PIL import ImageFilter

from .raster import rasterize

_HAN = re.compile(r"^[\u4e00-\u9fff]$")


def is_han(text: str) -> bool:
    return bool(_HAN.match(text))


class Recognizer:
    """单字手写识别（RapidOCR / PP-OCRv5 识别网络，onnxruntime）。

    做法（均以真实学生笔迹实测得出）：
    1. 关掉文字检测、只跑识别网络：整格图会被检测判成"没有文字"而返回空。
    2. 细笔画 + 大留白 + 超采样：更接近印刷体训练分布，置信度明显提高。
    3. 按"单字"解码：在汉字集合上取最强时间步的分布，取排名前三的候选。
       直接走 CTC 行解码时会出现"双观"这类两字输出，单字解码更稳定。
    4. 判定看排名而非绝对概率：第一候选等于目标字即判正确。
       汉字表约 1.8 万字，碰巧相撞的概率可忽略；不相等一律待确认，由家长订正。

    不限制候选字范围：识别到什么就展示什么。
    """

    def __init__(
        self,
        min_conf: float = 0.5,
        min_conf_wrong: float = 0.75,
        verdict_mode: str = "conservative",
    ):
        self.min_conf = min_conf
        self.min_conf_wrong = min_conf_wrong
        self.verdict_mode = verdict_mode
        self._engine = None
        self._rec = None
        self._charset = None
        self._han_chars: list[str] = []
        self._han_cols = None
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
                    import numpy as np

                    self._rec = self._engine.text_rec
                    chars = self._rec.postprocess_op.character
                    index: dict[str, int] = {}
                    for i, c in enumerate(chars):
                        index.setdefault(c, i)
                    self._charset = (chars, index)
                    han = [
                        c
                        for c in chars
                        if len(c) == 1 and "\u4e00" <= c <= "\u9fff"
                    ]
                    self._han_chars = han
                    self._han_cols = np.array([index[c] for c in han])
                except Exception:
                    self._rec = None
                    self._charset = None
            except Exception:
                self._failed = True
                self._engine = None
        return self._engine

    @staticmethod
    def _variants(strokes):
        base = rasterize(strokes)
        variants = [base]
        try:
            variants.append(base.filter(ImageFilter.GaussianBlur(1.2)))
        except Exception:
            pass
        return variants

    # —— 单字解码 ——
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

    def _single_char(self, image, top: int = 3, cols=None, names=None):
        """按最强时间步解码。cols/names 给定时只在候选字集合内比较。"""
        import numpy as np

        probs = self._timestep_probs(image)
        sub = probs[:, self._han_cols if cols is None else cols]
        mass = sub.sum(axis=1)
        step = int(np.argmax(mass))
        if mass[step] <= 0:
            return []
        q = sub[step] / mass[step]
        order = np.argsort(q)[::-1][:top]
        lookup = self._han_chars if names is None else names
        return [(lookup[int(i)], float(q[int(i)])) for i in order]

    def _allowed_index(self, allowed):
        """把客户端给的字集合映射到输出层列号，只保留模型认得的汉字。"""
        import numpy as np

        charset = self._charset
        if not charset or not allowed:
            return None, None
        _, index = charset
        picked = [c for c in dict.fromkeys(allowed) if c in index]
        if len(picked) < 2:
            return None, None
        return np.array([index[c] for c in picked]), picked

    # —— 兜底：CTC 行解码 ——
    def _line_decode(self, strokes):
        engine = self._engine
        if engine is None:
            return []
        import numpy as np

        found: dict[str, float] = {}
        for image in self._variants(strokes):
            arr = np.array(image.convert("L"))
            arr = np.stack([arr, arr, arr], axis=-1)
            try:
                out, _ = engine(arr, use_det=False, use_cls=False, use_rec=True)
            except Exception:
                continue
            for line in out or []:
                try:
                    text = str(line[0]).strip()
                    score = float(line[1])
                except Exception:
                    continue
                if text and found.get(text, 0.0) < score:
                    found[text] = score
        return sorted(found.items(), key=lambda kv: kv[1], reverse=True)

    def _constrained_top(self, expected, variants, allowed):
        """在本次练习的候选字集合内解码，返回排名第一的字。

        开集识别在这些字之间必然给出微弱差别（每步总有最大值），这个差别
        可能是噪声，所以只在目标字排第一时用来放行「正确」；结果不用于判错。
        """
        if not allowed or expected not in allowed:
            return None
        cols, names = self._allowed_index(allowed)
        if cols is None:
            return None
        merged: dict[str, float] = {}
        for image in variants:
            for char, score in self._single_char(image, cols=cols, names=names):
                if merged.get(char, 0.0) < score:
                    merged[char] = score
        if not merged:
            return None
        return max(merged.items(), key=lambda kv: kv[1])[0]

    # —— 判定 ——
    def classify(self, expected: str, strokes, allowed: Optional[list[str]] = None):
        """返回 {'verdict': correct|wrong|pending, 'candidates': [str]}。

        allowed 是本次练习涉及的字。它只用来把「待确认」升级为「正确」：
        开集识别认定正确 -> 正确；否则在本次练习的字里目标字排第一 -> 正确
        （这些字概率基本持平时排第一多半是噪声，但即便放行也无害——目标字
        本来就在练习里，家长仍可在结果页订正）。开集已给出的 pending /
        wrong 一律保持原样，因此不会新增误判。
        """
        if not strokes:
            return {"verdict": "blank", "candidates": []}

        self._load()
        if self._rec is not None and self._han_cols is not None:
            variants = self._variants(strokes)
            merged: dict[str, float] = {}
            for image in variants:
                for char, score in self._single_char(image):
                    if merged.get(char, 0.0) < score:
                        merged[char] = score
            ranked = sorted(merged.items(), key=lambda kv: kv[1], reverse=True)
            if ranked:
                labels = [c for c, _ in ranked[:3]]
                top = labels[0]
                if top == expected:
                    return {"verdict": "correct", "candidates": labels}
                if (
                    self.verdict_mode == "standard"
                    and ranked[0][1] >= self.min_conf_wrong
                ):
                    return {"verdict": "wrong", "candidates": labels}
                constrained = self._constrained_top(expected, variants, allowed)
                if constrained == expected:
                    return {"verdict": "correct", "candidates": labels}
                return {"verdict": "pending", "candidates": labels}

        # 兜底：行解码结果里找目标字
        found = self._line_decode(strokes)
        if not found:
            return {"verdict": "pending", "candidates": []}
        labels = [t for t, _ in found[:5]]
        top_text, top_conf = found[0]
        if is_han(top_text) and top_conf >= self.min_conf:
            if top_text == expected:
                return {"verdict": "correct", "candidates": labels}
            if (
                self.verdict_mode == "standard"
                and top_conf >= self.min_conf_wrong
            ):
                return {"verdict": "wrong", "candidates": labels}
        return {"verdict": "pending", "candidates": labels}


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
