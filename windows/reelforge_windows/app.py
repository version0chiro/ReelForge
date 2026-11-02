from __future__ import annotations

import shutil
import tempfile
import traceback
from pathlib import Path
from typing import Callable, List, Optional, Sequence

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QUrl, Signal, Slot
from PySide6.QtGui import QColor, QDesktopServices, QPalette
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QDoubleSpinBox,
    QFileDialog,
    QFrame,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSpinBox,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from .core import DetectionSettings, Highlight, VideoSource, detect_highlights
from .drive import PublicGoogleDrive
from .ffmpeg_engine import (
    VIDEO_EXTENSIONS,
    analyze_video,
    probe_video,
    render_reel,
)


class WorkerSignals(QObject):
    progress = Signal(str, float)
    result = Signal(object)
    error = Signal(str)
    finished = Signal()


class Worker(QRunnable):
    def __init__(self, operation: Callable[[Callable[[str, float], None]], object]):
        super().__init__()
        self.operation = operation
        self.signals = WorkerSignals()

    @Slot()
    def run(self) -> None:
        try:
            result = self.operation(self.signals.progress.emit)
        except Exception as exc:  # UI boundary: surface a readable failure.
            traceback.print_exc()
            self.signals.error.emit(str(exc) or type(exc).__name__)
        else:
            self.signals.result.emit(result)
        finally:
            self.signals.finished.emit()


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("ReelForge — Gameplay Reels")
        self.resize(1280, 820)
        self.setMinimumSize(1040, 700)
        self.thread_pool = QThreadPool.globalInstance()
        self.sources: List[VideoSource] = []
        self.highlights: List[Highlight] = []
        self.temporary_directories: List[Path] = []
        self.last_export: Optional[Path] = None
        self._busy = False

        root = QWidget()
        self.setCentralWidget(root)
        layout = QHBoxLayout(root)
        layout.setContentsMargins(18, 18, 18, 18)
        layout.setSpacing(16)
        layout.addWidget(self._build_source_panel(), 3)
        layout.addWidget(self._build_editor_panel(), 7)

        self.statusBar().showMessage("Add local videos or paste a public Drive folder.")
        self._refresh_controls()

    def _build_source_panel(self) -> QWidget:
        panel = QFrame()
        panel.setObjectName("panel")
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(16, 16, 16, 16)
        layout.setSpacing(12)

        title = QLabel("ReelForge")
        title.setObjectName("title")
        subtitle = QLabel("GAMEPLAY MONTAGE CUTTER")
        subtitle.setObjectName("eyebrow")
        layout.addWidget(title)
        layout.addWidget(subtitle)

        drive_box = QGroupBox("PUBLIC GOOGLE DRIVE")
        drive_layout = QVBoxLayout(drive_box)
        self.drive_url = QLineEdit()
        self.drive_url.setPlaceholderText("https://drive.google.com/drive/folders/…")
        self.drive_url.returnPressed.connect(self.import_drive_folder)
        self.drive_url.textChanged.connect(lambda: self._refresh_controls())
        self.drive_button = QPushButton("Import and improve folder")
        self.drive_button.clicked.connect(self.import_drive_folder)
        drive_note = QLabel(
            "Public folders only: set General access to “Anyone with the link”. "
            "MP4, MOV, and M4V files are downloaded temporarily."
        )
        drive_note.setWordWrap(True)
        drive_note.setObjectName("muted")
        drive_layout.addWidget(self.drive_url)
        drive_layout.addWidget(self.drive_button)
        drive_layout.addWidget(drive_note)
        layout.addWidget(drive_box)

        local_row = QHBoxLayout()
        self.add_button = QPushButton("Add local videos")
        self.add_button.clicked.connect(self.add_local_videos)
        self.remove_button = QPushButton("Remove")
        self.remove_button.clicked.connect(self.remove_selected_sources)
        local_row.addWidget(self.add_button)
        local_row.addWidget(self.remove_button)
        layout.addLayout(local_row)

        self.source_list = QListWidget()
        self.source_list.setAlternatingRowColors(True)
        self.source_list.itemSelectionChanged.connect(self._refresh_controls)
        layout.addWidget(self.source_list, 1)

        self.source_summary = QLabel("0 source videos")
        self.source_summary.setObjectName("muted")
        layout.addWidget(self.source_summary)
        return panel

    def _build_editor_panel(self) -> QWidget:
        panel = QFrame()
        panel.setObjectName("panel")
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(18, 18, 18, 18)
        layout.setSpacing(14)

        heading_row = QHBoxLayout()
        heading = QVBoxLayout()
        title = QLabel("Build a 9:16 gameplay Reel")
        title.setObjectName("sectionTitle")
        note = QLabel(
            "Sound peaks, motion, scene changes, and sustained action are scored "
            "across every source."
        )
        note.setObjectName("muted")
        note.setWordWrap(True)
        heading.addWidget(title)
        heading.addWidget(note)
        heading_row.addLayout(heading, 1)
        self.scan_button = QPushButton("Find epic sequences")
        self.scan_button.setObjectName("primary")
        self.scan_button.clicked.connect(self.scan_sources)
        heading_row.addWidget(self.scan_button)
        layout.addLayout(heading_row)

        settings = QGroupBox("MONTAGE SETTINGS")
        settings_layout = QGridLayout(settings)
        self.target_duration = QSpinBox()
        self.target_duration.setRange(3, 60)
        self.target_duration.setValue(15)
        self.target_duration.setSuffix(" sec")
        self.sequence_duration = QDoubleSpinBox()
        self.sequence_duration.setRange(1.0, 8.0)
        self.sequence_duration.setSingleStep(0.5)
        self.sequence_duration.setValue(3.5)
        self.sequence_duration.setSuffix(" sec")
        self.audio_weight = QDoubleSpinBox()
        self.audio_weight.setRange(0.0, 1.0)
        self.audio_weight.setSingleStep(0.05)
        self.audio_weight.setValue(0.55)
        self.sensitivity = QDoubleSpinBox()
        self.sensitivity.setRange(0.0, 1.0)
        self.sensitivity.setSingleStep(0.05)
        self.sensitivity.setValue(0.58)
        self.order = QComboBox()
        self.order.addItem("Hook first", True)
        self.order.addItem("Source order", False)
        self.framing = QComboBox()
        self.framing.addItem("Adaptive quality", "adaptive")
        self.framing.addItem("Full frame + blur", "fit")
        self.framing.addItem("Fill 9:16 crop", "crop")

        settings_layout.addWidget(QLabel("Target length"), 0, 0)
        settings_layout.addWidget(self.target_duration, 0, 1)
        settings_layout.addWidget(QLabel("Sequence length"), 0, 2)
        settings_layout.addWidget(self.sequence_duration, 0, 3)
        settings_layout.addWidget(QLabel("Sound weight"), 1, 0)
        settings_layout.addWidget(self.audio_weight, 1, 1)
        settings_layout.addWidget(QLabel("Sensitivity"), 1, 2)
        settings_layout.addWidget(self.sensitivity, 1, 3)
        settings_layout.addWidget(QLabel("Order"), 2, 0)
        settings_layout.addWidget(self.order, 2, 1)
        settings_layout.addWidget(QLabel("Framing"), 2, 2)
        settings_layout.addWidget(self.framing, 2, 3)
        layout.addWidget(settings)

        sequence_header = QHBoxLayout()
        sequence_header.addWidget(QLabel("SELECTED SEQUENCES"))
        sequence_header.addStretch(1)
        self.move_up_button = QPushButton("Move up")
        self.move_up_button.clicked.connect(lambda: self._move_row(-1))
        self.move_down_button = QPushButton("Move down")
        self.move_down_button.clicked.connect(lambda: self._move_row(1))
        sequence_header.addWidget(self.move_up_button)
        sequence_header.addWidget(self.move_down_button)
        layout.addLayout(sequence_header)

        self.cut_table = QTableWidget(0, 7)
        self.cut_table.setHorizontalHeaderLabels(
            ["Use", "Source", "In", "Out", "Score", "Signals", "Crop focus"]
        )
        self.cut_table.setSelectionBehavior(QTableWidget.SelectRows)
        self.cut_table.setAlternatingRowColors(True)
        self.cut_table.horizontalHeader().setStretchLastSection(True)
        self.cut_table.setColumnWidth(0, 44)
        self.cut_table.setColumnWidth(1, 250)
        self.cut_table.setColumnWidth(2, 75)
        self.cut_table.setColumnWidth(3, 75)
        self.cut_table.setColumnWidth(4, 65)
        self.cut_table.setColumnWidth(5, 120)
        layout.addWidget(self.cut_table, 1)

        export_box = QGroupBox("ENHANCED REELS EXPORT")
        export_layout = QHBoxLayout(export_box)
        export_note = QLabel(
            "1080×1920 H.264 · 30 fps · AAC · Lanczos upscale + restrained sharpening"
        )
        export_note.setObjectName("muted")
        export_layout.addWidget(export_note, 1)
        self.export_button = QPushButton("Export improved Reel")
        self.export_button.setObjectName("primary")
        self.export_button.clicked.connect(self.export_reel)
        self.open_export_button = QPushButton("Open last export")
        self.open_export_button.clicked.connect(self.open_last_export)
        export_layout.addWidget(self.export_button)
        export_layout.addWidget(self.open_export_button)
        layout.addWidget(export_box)

        progress_row = QHBoxLayout()
        self.progress_label = QLabel("Ready")
        self.progress_label.setObjectName("muted")
        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 1000)
        self.progress_bar.setValue(0)
        progress_row.addWidget(self.progress_label, 1)
        progress_row.addWidget(self.progress_bar, 2)
        layout.addLayout(progress_row)
        return panel

    def _start_worker(
        self,
        operation: Callable[[Callable[[str, float], None]], object],
        on_result: Callable[[object], None],
    ) -> None:
        if self._busy:
            return
        self._busy = True
        self.progress_bar.setValue(0)
        self._refresh_controls()
        worker = Worker(operation)
        worker.signals.progress.connect(self._set_progress)
        worker.signals.result.connect(on_result)
        worker.signals.error.connect(self._show_error)
        worker.signals.finished.connect(self._worker_finished)
        self.thread_pool.start(worker)

    @Slot(str, float)
    def _set_progress(self, message: str, progress: float) -> None:
        self.progress_label.setText(message)
        self.progress_bar.setValue(int(max(0.0, min(1.0, progress)) * 1000))
        self.statusBar().showMessage(message)

    @Slot(str)
    def _show_error(self, message: str) -> None:
        QMessageBox.critical(self, "ReelForge", message)
        self.progress_label.setText("Operation failed")
        self.statusBar().showMessage(message)

    @Slot()
    def _worker_finished(self) -> None:
        self._busy = False
        self._refresh_controls()

    def _refresh_controls(self) -> None:
        has_sources = bool(self.sources)
        has_cuts = self.cut_table.rowCount() > 0
        self.drive_button.setEnabled(not self._busy and bool(self.drive_url.text().strip()))
        self.add_button.setEnabled(not self._busy)
        self.remove_button.setEnabled(not self._busy and bool(self.source_list.selectedItems()))
        self.scan_button.setEnabled(not self._busy and has_sources)
        self.export_button.setEnabled(not self._busy and has_cuts)
        self.open_export_button.setEnabled(
            not self._busy and self.last_export is not None and self.last_export.exists()
        )
        self.move_up_button.setEnabled(not self._busy and has_cuts)
        self.move_down_button.setEnabled(not self._busy and has_cuts)

    def add_local_videos(self) -> None:
        files, _ = QFileDialog.getOpenFileNames(
            self,
            "Choose gameplay videos",
            "",
            "Videos (*.mp4 *.mov *.m4v *.mkv *.webm *.avi)",
        )
        if files:
            self._import_paths([Path(value) for value in files])

    def _import_paths(self, paths: Sequence[Path]) -> None:
        unique = []
        existing = {source.path.resolve() for source in self.sources}
        for path in paths:
            resolved = path.resolve()
            if (
                resolved not in existing
                and resolved.suffix.lower() in VIDEO_EXTENSIONS
            ):
                unique.append(resolved)
                existing.add(resolved)
        if not unique:
            return

        def operation(progress):
            imported = []
            for index, path in enumerate(unique):
                progress(
                    f"Reading {path.name}",
                    index / max(1, len(unique)),
                )
                imported.append(probe_video(path))
            progress("Source videos ready", 1.0)
            return imported

        self._start_worker(operation, self._finish_local_import)

    @Slot(object)
    def _finish_local_import(self, result: object) -> None:
        self.sources.extend(result)
        self.highlights = []
        self._populate_sources()
        self._populate_cuts()
        self._set_progress(
            f"{len(self.sources)} source videos ready. Find epic sequences next.",
            0.0,
        )

    def import_drive_folder(self) -> None:
        url = self.drive_url.text().strip()
        if not url:
            return

        def operation(progress):
            client = PublicGoogleDrive()
            folder_name, videos = client.discover(url, progress)
            temporary = Path(tempfile.mkdtemp(prefix="ReelForge-PublicDrive-"))
            try:
                paths = client.download(videos, temporary, progress)
                sources = []
                for index, path in enumerate(paths):
                    progress(
                        f"Reading {path.name}",
                        index / max(1, len(paths)),
                    )
                    sources.append(probe_video(path))
                return folder_name, sources, temporary
            except Exception:
                shutil.rmtree(temporary, ignore_errors=True)
                raise

        self._start_worker(operation, self._finish_drive_import)

    @Slot(object)
    def _finish_drive_import(self, result: object) -> None:
        folder_name, sources, temporary = result
        self.temporary_directories.append(temporary)
        existing = {source.path.resolve() for source in self.sources}
        for source in sources:
            resolved = source.path.resolve()
            if resolved not in existing:
                self.sources.append(source)
                existing.add(resolved)
        self.highlights = []
        self._populate_sources()
        self._populate_cuts()
        self._set_progress(
            f"Imported {len(sources)} public videos from {folder_name}. Ready to scan.",
            0.0,
        )

    def remove_selected_sources(self) -> None:
        rows = sorted(
            {self.source_list.row(item) for item in self.source_list.selectedItems()},
            reverse=True,
        )
        for row in rows:
            if 0 <= row < len(self.sources):
                self.sources.pop(row)
        self.highlights = []
        self._populate_sources()
        self._populate_cuts()

    def _populate_sources(self) -> None:
        self.source_list.clear()
        total = 0.0
        for index, source in enumerate(self.sources, start=1):
            total += source.duration
            state = "signals ready" if source.samples else "not scanned"
            self.source_list.addItem(
                f"{index:02d}  {source.name}\n"
                f"      {source.duration:.1f}s · {source.resolution_label} · {state}"
            )
        self.source_summary.setText(
            f"{len(self.sources)} source videos · {total:.1f} seconds"
        )
        self._refresh_controls()

    def scan_sources(self) -> None:
        settings = DetectionSettings(
            target_duration=float(self.target_duration.value()),
            sequence_duration=float(self.sequence_duration.value()),
            audio_weight=float(self.audio_weight.value()),
            sensitivity=float(self.sensitivity.value()),
            hook_first=bool(self.order.currentData()),
        )

        def operation(progress):
            analyzed = []
            count = max(1, len(self.sources))
            for index, source in enumerate(self.sources):
                def source_progress(message, local_progress, offset=index):
                    progress(message, (offset + local_progress) / count)

                analyzed.append(analyze_video(source.path, source_progress))
            highlights = detect_highlights(analyzed, settings)
            if not highlights:
                raise RuntimeError(
                    "No usable sequences were detected. Try higher sensitivity."
                )
            progress("Epic sequence cut list ready", 1.0)
            return analyzed, highlights

        self._start_worker(operation, self._finish_scan)

    @Slot(object)
    def _finish_scan(self, result: object) -> None:
        self.sources, self.highlights = result
        self._populate_sources()
        self._populate_cuts()
        duration = sum(item.duration for item in self.highlights)
        self._set_progress(
            f"Selected {len(self.highlights)} sequences · {duration:.1f}s Reel",
            1.0,
        )

    def _populate_cuts(self) -> None:
        self.cut_table.setRowCount(0)
        for highlight_index, highlight in enumerate(self.highlights):
            row = self.cut_table.rowCount()
            self.cut_table.insertRow(row)
            use_item = QTableWidgetItem()
            use_item.setFlags(
                Qt.ItemIsEnabled | Qt.ItemIsSelectable | Qt.ItemIsUserCheckable
            )
            use_item.setCheckState(Qt.Checked)
            use_item.setData(Qt.UserRole, highlight.source_index)
            use_item.setData(Qt.UserRole + 1, highlight_index)
            self.cut_table.setItem(row, 0, use_item)
            self.cut_table.setItem(row, 1, QTableWidgetItem(highlight.source_name))
            self.cut_table.setItem(row, 2, QTableWidgetItem(f"{highlight.start:.2f}"))
            self.cut_table.setItem(row, 3, QTableWidgetItem(f"{highlight.end:.2f}"))
            self.cut_table.setItem(row, 4, QTableWidgetItem(f"{highlight.score:.2f}"))
            self.cut_table.setItem(
                row, 5, QTableWidgetItem(" + ".join(highlight.reasons))
            )
            self.cut_table.setItem(
                row, 6, QTableWidgetItem(f"{highlight.crop_x * 100:.0f}%")
            )
            for column in (1, 4, 5, 6):
                item = self.cut_table.item(row, column)
                item.setFlags(item.flags() & ~Qt.ItemIsEditable)
        self._refresh_controls()

    def _selected_highlights(self) -> List[Highlight]:
        selected = []
        for row in range(self.cut_table.rowCount()):
            use_item = self.cut_table.item(row, 0)
            if use_item is None or use_item.checkState() != Qt.Checked:
                continue
            source_index = int(use_item.data(Qt.UserRole))
            highlight_index = int(use_item.data(Qt.UserRole + 1))
            start = float(self.cut_table.item(row, 2).text())
            end = float(self.cut_table.item(row, 3).text())
            source = self.sources[source_index]
            start = max(0.0, min(start, source.duration))
            end = max(start, min(end, source.duration))
            if end - start < 0.5:
                raise ValueError(
                    f"The cut for {source.name} must be at least 0.5 seconds."
                )
            if not 0 <= highlight_index < len(self.highlights):
                continue
            original = self.highlights[highlight_index]
            selected.append(
                Highlight(
                    source_index=source_index,
                    source_name=source.name,
                    start=start,
                    end=end,
                    peak=original.peak,
                    score=original.score,
                    peak_score=original.peak_score,
                    sequence_strength=original.sequence_strength,
                    crop_x=original.crop_x,
                    reasons=original.reasons,
                )
            )
        if not selected:
            raise ValueError("Select at least one sequence to export.")
        return selected

    def _move_row(self, direction: int) -> None:
        row = self.cut_table.currentRow()
        target = row + direction
        if row < 0 or target < 0 or target >= self.cut_table.rowCount():
            return
        values = []
        for column in range(self.cut_table.columnCount()):
            item = self.cut_table.takeItem(row, column)
            values.append(item)
        target_values = []
        for column in range(self.cut_table.columnCount()):
            target_values.append(self.cut_table.takeItem(target, column))
        for column, item in enumerate(values):
            self.cut_table.setItem(target, column, item)
        for column, item in enumerate(target_values):
            self.cut_table.setItem(row, column, item)
        self.cut_table.selectRow(target)

    def export_reel(self) -> None:
        try:
            highlights = self._selected_highlights()
        except (TypeError, ValueError) as exc:
            self._show_error(str(exc))
            return
        default_name = str(Path.home() / "Videos" / "ReelForge-improved-reel.mp4")
        output_value, _ = QFileDialog.getSaveFileName(
            self,
            "Export improved Reel",
            default_name,
            "MP4 Video (*.mp4)",
        )
        if not output_value:
            return
        output = Path(output_value)
        if output.suffix.lower() != ".mp4":
            output = output.with_suffix(".mp4")
        framing = str(self.framing.currentData())

        def operation(progress):
            return render_reel(
                self.sources,
                highlights,
                output,
                framing=framing,
                status=progress,
            )

        self._start_worker(operation, self._finish_export)

    @Slot(object)
    def _finish_export(self, result: object) -> None:
        self.last_export = Path(result)
        self._set_progress(f"Saved {self.last_export.name}", 1.0)
        QMessageBox.information(
            self,
            "ReelForge",
            f"Your enhanced Reel is ready:\n{self.last_export}",
        )

    def open_last_export(self) -> None:
        if self.last_export is not None:
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.last_export)))

    def closeEvent(self, event) -> None:
        for directory in self.temporary_directories:
            if directory.name.startswith("ReelForge-PublicDrive-"):
                shutil.rmtree(directory, ignore_errors=True)
        event.accept()


def apply_dark_palette(app: QApplication) -> None:
    palette = QPalette()
    palette.setColor(QPalette.Window, QColor("#080b11"))
    palette.setColor(QPalette.WindowText, QColor("#f4f6f8"))
    palette.setColor(QPalette.Base, QColor("#0d1119"))
    palette.setColor(QPalette.AlternateBase, QColor("#121923"))
    palette.setColor(QPalette.ToolTipBase, QColor("#f4f6f8"))
    palette.setColor(QPalette.ToolTipText, QColor("#080b11"))
    palette.setColor(QPalette.Text, QColor("#f4f6f8"))
    palette.setColor(QPalette.Button, QColor("#151c26"))
    palette.setColor(QPalette.ButtonText, QColor("#f4f6f8"))
    palette.setColor(QPalette.BrightText, QColor("#d9ff52"))
    palette.setColor(QPalette.Highlight, QColor("#b9ed3b"))
    palette.setColor(QPalette.HighlightedText, QColor("#050805"))
    palette.setColor(QPalette.PlaceholderText, QColor("#758091"))
    app.setPalette(palette)
    app.setStyleSheet(
        """
        QFrame#panel { background: #0b1018; border: 1px solid #1b2633; border-radius: 14px; }
        QLabel#title { font-size: 25px; font-weight: 800; color: #d9ff52; }
        QLabel#sectionTitle { font-size: 21px; font-weight: 750; }
        QLabel#eyebrow { color: #8d98a8; font-size: 10px; font-weight: 700; }
        QLabel#muted { color: #8d98a8; }
        QGroupBox { border: 1px solid #243142; border-radius: 10px; margin-top: 10px;
                    padding-top: 10px; font-weight: 700; color: #b9ed3b; }
        QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 4px; }
        QPushButton { min-height: 30px; padding: 3px 12px; border-radius: 7px;
                      border: 1px solid #354459; background: #182230; }
        QPushButton:hover { border-color: #b9ed3b; }
        QPushButton#primary { background: #b9ed3b; color: #071006; border: none;
                              font-weight: 800; min-height: 36px; }
        QPushButton:disabled { color: #596373; background: #121821; border-color: #202a37; }
        QLineEdit, QSpinBox, QDoubleSpinBox, QComboBox {
            min-height: 29px; border: 1px solid #2d3a4b; border-radius: 6px;
            background: #0b111a; padding: 2px 7px;
        }
        QListWidget, QTableWidget { border: 1px solid #243142; border-radius: 8px;
                                   background: #080d14; gridline-color: #202a36; }
        QHeaderView::section { background: #141d28; padding: 7px; border: none;
                               border-right: 1px solid #263344; font-weight: 700; }
        QProgressBar { border: 1px solid #2b394a; border-radius: 5px; text-align: center;
                       background: #0b1118; }
        QProgressBar::chunk { background: #b9ed3b; border-radius: 4px; }
        """
    )
