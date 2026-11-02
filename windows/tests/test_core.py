from __future__ import annotations

import sys
import unittest
from pathlib import Path


WINDOWS_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WINDOWS_ROOT))

from reelforge_windows.core import (  # noqa: E402
    DetectionSettings,
    FeatureSample,
    VideoSource,
    detect_highlights,
    normalize,
)
from reelforge_windows.drive import (  # noqa: E402
    folder_id_from_url,
    parse_folder_html,
)
from reelforge_windows.ffmpeg_engine import build_filter_graph  # noqa: E402


def source(name: str, peak_index: int, has_audio: bool = True) -> VideoSource:
    samples = []
    for index in range(80):
        strength = 1.0 if abs(index - peak_index) <= 4 else 0.05
        samples.append(
            FeatureSample(
                time=index * 0.25,
                audio_rms=strength if has_audio else 0.0,
                audio_onset=strength * 0.8 if has_audio else 0.0,
                motion=strength * 0.9,
                scene=strength * 0.6,
                crop_x=0.25 if peak_index < 30 else 0.75,
            )
        )
    return VideoSource(
        path=Path(name),
        name=name,
        duration=20.0,
        width=1920,
        height=1080,
        frame_rate=60.0,
        has_audio=has_audio,
        samples=samples,
    )


class CoreTests(unittest.TestCase):
    def test_constant_normalization_is_zero(self) -> None:
        self.assertEqual(normalize([4.0, 4.0, 4.0]), [0.0, 0.0, 0.0])

    def test_detector_uses_multiple_sources_and_hook_first(self) -> None:
        sources = [source("one.mp4", 16), source("two.mp4", 52)]
        highlights = detect_highlights(
            sources,
            DetectionSettings(
                target_duration=7.0,
                sequence_duration=3.5,
                audio_weight=0.55,
                sensitivity=0.58,
                hook_first=True,
            ),
        )
        self.assertEqual({item.source_index for item in highlights}, {0, 1})
        self.assertLessEqual(sum(item.duration for item in highlights), 7.01)
        self.assertGreaterEqual(highlights[0].score, highlights[1].score)

    def test_visual_only_source_still_detects(self) -> None:
        highlights = detect_highlights(
            [source("silent.mp4", 35, has_audio=False)],
            DetectionSettings(target_duration=4.0, sequence_duration=4.0),
        )
        self.assertEqual(len(highlights), 1)
        self.assertIn("motion", highlights[0].reasons)

    def test_filter_graph_contains_upscale_audio_and_concat(self) -> None:
        sources = [
            source("landscape.mp4", 20),
            source("silent.mp4", 40, has_audio=False),
        ]
        highlights = detect_highlights(
            sources,
            DetectionSettings(target_duration=7.0, sequence_duration=3.5),
        )
        graph = build_filter_graph(sources, highlights, "adaptive")
        self.assertIn("scale=1080:1920", graph)
        self.assertIn("flags=lanczos", graph)
        self.assertIn("unsharp=", graph)
        self.assertIn("anullsrc=", graph)
        self.assertIn("concat=n=2:v=1:a=1", graph)


class DriveTests(unittest.TestCase):
    def test_public_folder_url(self) -> None:
        folder_id = folder_id_from_url(
            "https://drive.google.com/drive/folders/"
            "1AbCdEfGhIjKlMnOpQrStUvWxYz?usp=sharing"
        )
        self.assertEqual(folder_id, "1AbCdEfGhIjKlMnOpQrStUvWxYz")

    def test_folder_html_parser(self) -> None:
        page = """
        <html><head><title>Gameplay clips</title></head><body>
          <a href="https://drive.google.com/file/d/1234567890abcdefghijk/view">
            match-one.mp4
          </a>
          <a href="https://drive.google.com/drive/folders/abcdefghijk1234567890">
            Finals
          </a>
        </body></html>
        """
        name, entries = parse_folder_html(page, "root1234567890")
        self.assertEqual(name, "Gameplay clips")
        self.assertEqual(entries[0], ("1234567890abcdefghijk", "match-one.mp4", False))
        self.assertEqual(entries[1], ("abcdefghijk1234567890", "Finals", True))


if __name__ == "__main__":
    unittest.main()
