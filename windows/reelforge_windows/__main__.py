from __future__ import annotations

import sys

from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication, QStyleFactory

from .app import MainWindow, apply_dark_palette
from .ffmpeg_engine import find_tool


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("ReelForge")
    app.setOrganizationName("ReelForge")
    app.setStyle(QStyleFactory.create("Fusion"))
    apply_dark_palette(app)
    window = MainWindow()
    window.show()
    if "--self-test" in sys.argv:
        if getattr(sys, "frozen", False):
            find_tool("ffmpeg")
            find_tool("ffprobe")
        QTimer.singleShot(250, app.quit)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
