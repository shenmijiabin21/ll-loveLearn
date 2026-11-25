import re
import threading
from typing import Optional

_HAN = re.compile(r"^[一-鿿]$")


def is_han(text: str) -> bool:
    return bool(_HAN.match(text))


class Recognizer:
    """单字手写识别（RapidOCR / PP-OCR ONNX，onnxruntime 推理）。

    相比 PaddlePaddle 版本：内存从约 400-600MB 降到约 100-150MB（框架级下降），
    模型同为 PP-OCR 系列、精度不变。OCR 置信度偏"过度自信"，min_conf 需按真实
    学生笔迹样本校准；不确定时返回 pending，家长人工订正兜底。
    """

    def __init__(self, min_conf: float = 0.6, verdict_mode: str = "conservative"):
        self.min_conf = min_conf
        self.verdict_mode = verdict_mode
        self._engine = None
        self._failed = False
        self._lock = threading.Lock()

    def _load(self):
        if self._engine is not None or self._failed:
            return self._engine
        with self._lock:
            if self._engine is not None or self._failed:
                return self._engine
            try:
                from rapidocr_onnxruntime import RapidOCR

                self._engine = RapidOCR()
            except Exception:
                self._failed = True
                self._engine = None
        return self._engine

    def recognize(self, image):
        """image: PIL Image -> list[(text, confidence)] 降序，可为空。"""
        engine = self._load()
        if engine is None:
            return []
        import numpy as np

        arr = np.array(image)
        if arr.ndim == 2:  # 灰度 -> 3 通道，RapidOCR 期望 RGB/BGR
            arr = np.stack([arr, arr, arr], axis=-1)
        try:
            result, _ = engine(arr)
        except Exception:
            return []
        items = []
        for line in result or []:
            try:
                text = str(line[1]).strip()
                conf = float(line[2])
                if text:
                    items.append((text, conf))
            except Exception:
                continue
        items.sort(key=lambda x: x[1], reverse=True)
        return items

    def classify(self, expected: str, image) -> dict:
        """返回 {'verdict': correct|wrong|pending, 'candidates': [str]}。

        OCR 只给一个最优假设，无法用 ML Kit 那种"次优间隔"判定，故只用置信度阈值：
        汉字 + 置信度达标才自动判定，否则交给家长。
        """
        candidates = self.recognize(image)
        if not candidates:
            return {"verdict": "pending", "candidates": []}
        top_text, top_conf = candidates[0]
        plausible = is_han(top_text)
        confident = top_conf >= self.min_conf
        if plausible and confident:
            if top_text == expected:
                verdict = "correct"
            elif self.verdict_mode == "standard":
                verdict = "wrong"
            else:
                verdict = "pending"
        else:
            verdict = "pending"
        return {"verdict": verdict, "candidates": [t for t, _ in candidates[:5]]}


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
