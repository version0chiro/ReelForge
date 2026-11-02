from __future__ import annotations

import html as html_module
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional, Set, Tuple
from urllib.parse import parse_qsl, urlencode, urljoin, urlparse, urlunparse

import requests
from bs4 import BeautifulSoup


StatusCallback = Optional[Callable[[str, float], None]]
SUPPORTED_VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v"}
FOLDER_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Safari/537.36"
)


class PublicDriveError(RuntimeError):
    pass


@dataclass(frozen=True)
class PublicDriveVideo:
    file_id: str
    name: str
    relative_path: Path


def folder_id_from_url(value: str) -> str:
    parsed = urlparse(value.strip())
    if parsed.scheme not in {"http", "https"} or parsed.netloc.lower() not in {
        "drive.google.com",
        "docs.google.com",
    }:
        raise PublicDriveError(
            "Paste a Google Drive folder URL from drive.google.com."
        )
    segments = [segment for segment in parsed.path.split("/") if segment]
    try:
        marker = segments.index("folders")
        folder_id = segments[marker + 1]
    except (ValueError, IndexError) as exc:
        raise PublicDriveError(
            "Use a folder URL such as https://drive.google.com/drive/folders/..."
        ) from exc
    if len(folder_id) < 10 or not re.fullmatch(r"[A-Za-z0-9_-]+", folder_id):
        raise PublicDriveError("The Google Drive folder ID is not valid.")
    return folder_id


def sanitize_component(value: str) -> str:
    cleaned = re.sub(r"[\x00-\x1f<>:\"/\\|?*]", "_", value).strip(" .")
    if not cleaned or cleaned in {".", ".."}:
        return "Untitled"
    return cleaned[:180]


def parse_folder_html(
    page: str, current_folder_id: str
) -> Tuple[str, List[Tuple[str, str, bool]]]:
    soup = BeautifulSoup(page, "html.parser")
    if soup.title is None:
        raise PublicDriveError(
            "Google returned a folder page ReelForge could not understand."
        )
    name = soup.title.get_text(" ", strip=True)
    if not name:
        raise PublicDriveError(
            "Google returned a folder page without a readable name."
        )

    entries: List[Tuple[str, str, bool]] = []
    seen: Set[Tuple[str, str]] = set()
    for anchor in soup.find_all("a"):
        href = anchor.get("href", "")
        if not isinstance(href, str):
            continue
        visible_name = anchor.get_text(" ", strip=True)
        if not visible_name:
            continue
        file_match = re.match(
            r"https://drive\.google\.com/file/d/([A-Za-z0-9_-]{10,})/(?:view|preview)",
            href,
            flags=re.IGNORECASE,
        )
        if file_match:
            key = ("file", file_match.group(1))
            if key not in seen:
                entries.append((file_match.group(1), visible_name, False))
                seen.add(key)
            continue
        try:
            child_id = folder_id_from_url(href)
        except PublicDriveError:
            continue
        key = ("folder", child_id)
        if child_id != current_folder_id and key not in seen:
            entries.append((child_id, visible_name, True))
            seen.add(key)
    return name, entries


class PublicGoogleDrive:
    def __init__(self, maximum_videos: int = 200, maximum_depth: int = 8):
        self.maximum_videos = maximum_videos
        self.maximum_depth = maximum_depth
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": FOLDER_USER_AGENT})

    def discover(
        self, folder_url: str, status: StatusCallback = None
    ) -> Tuple[str, List[PublicDriveVideo]]:
        root_id = folder_id_from_url(folder_url)
        visited_folders: Set[str] = set()
        visited_files: Set[str] = set()
        videos: List[PublicDriveVideo] = []
        root_name = ["Google Drive Montage"]

        def walk(folder_id: str, path: Path, depth: int) -> None:
            if depth > self.maximum_depth or folder_id in visited_folders:
                return
            visited_folders.add(folder_id)
            response = self.session.get(
                "https://drive.google.com/embeddedfolderview",
                params={"id": folder_id},
                timeout=(15, 60),
            )
            if response.status_code != 200:
                raise PublicDriveError(
                    "The folder could not be opened. Set General access to "
                    "'Anyone with the link' and try again."
                )
            folder_name, entries = parse_folder_html(response.text, folder_id)
            if depth == 0:
                root_name[0] = sanitize_component(folder_name)
            if status:
                label = str(path) if str(path) != "." else folder_name
                status(
                    f"Reading public folder: {label}",
                    min(0.95, len(visited_folders) / 20.0),
                )

            for entry_id, entry_name, is_folder in entries:
                safe_name = sanitize_component(entry_name)
                if is_folder:
                    walk(entry_id, path / safe_name, depth + 1)
                    continue
                if (
                    entry_id in visited_files
                    or Path(safe_name).suffix.lower()
                    not in SUPPORTED_VIDEO_EXTENSIONS
                ):
                    continue
                if len(videos) >= self.maximum_videos:
                    raise PublicDriveError(
                        f"The folder contains more than {self.maximum_videos} videos. "
                        "Use a smaller folder for one montage."
                    )
                visited_files.add(entry_id)
                videos.append(
                    PublicDriveVideo(
                        file_id=entry_id,
                        name=safe_name,
                        relative_path=path / safe_name,
                    )
                )

        walk(root_id, Path(), 0)
        if not videos:
            raise PublicDriveError(
                "No public MP4, MOV, or M4V videos were found in the folder."
            )
        return root_name[0], videos

    def download(
        self,
        videos: List[PublicDriveVideo],
        destination: Path,
        status: StatusCallback = None,
    ) -> List[Path]:
        destination.mkdir(parents=True, exist_ok=True)
        downloaded: List[Path] = []
        for index, video in enumerate(videos):
            if status:
                status(
                    f"Downloading {video.name}",
                    index / max(1, len(videos)),
                )
            target = destination.joinpath(
                *(sanitize_component(part) for part in video.relative_path.parts)
            )
            target.parent.mkdir(parents=True, exist_ok=True)
            self._download_file(video, target)
            downloaded.append(target)
            if status:
                status(
                    f"Downloaded {video.name}",
                    (index + 1) / max(1, len(videos)),
                )
        return downloaded

    def _download_file(self, video: PublicDriveVideo, target: Path) -> None:
        next_url = "https://drive.google.com/uc?" + urlencode(
            {"export": "download", "id": video.file_id}
        )
        for _ in range(4):
            response = self.session.get(
                next_url,
                timeout=(15, 60 * 30),
                stream=True,
                allow_redirects=True,
            )
            if not 200 <= response.status_code < 300:
                raise PublicDriveError(
                    f"Google Drive returned HTTP {response.status_code} for {video.name}."
                )
            content_type = response.headers.get("Content-Type", "").lower()
            if (
                "Content-Disposition" in response.headers
                or "text/html" not in content_type
            ):
                partial = target.with_name(target.name + ".part")
                try:
                    with partial.open("wb") as output:
                        for chunk in response.iter_content(chunk_size=1024 * 1024):
                            if chunk:
                                output.write(chunk)
                    partial.replace(target)
                    return
                finally:
                    if partial.exists():
                        partial.unlink()

            next_url = self._confirmation_url(response.text, response.url)
            if next_url is None:
                break
        raise PublicDriveError(
            f"Google Drive would not provide a public download for {video.name}. "
            "Check its sharing permission or download quota."
        )

    @staticmethod
    def _confirmation_url(page: str, base_url: str) -> Optional[str]:
        soup = BeautifulSoup(page, "html.parser")
        for anchor in soup.find_all("a", href=True):
            href = str(anchor["href"])
            if href.startswith("/uc?") and "export=download" in href:
                return urljoin(base_url, html_module.unescape(href))

        form = soup.find("form", id="download-form")
        if form is not None and form.get("action"):
            action = urljoin(base_url, html_module.unescape(str(form["action"])))
            parsed = urlparse(action)
            query = dict(parse_qsl(parsed.query, keep_blank_values=True))
            for field in form.find_all("input", attrs={"type": "hidden"}):
                if field.get("name") is not None:
                    query[str(field["name"])] = html_module.unescape(
                        str(field.get("value", ""))
                    )
            return urlunparse(parsed._replace(query=urlencode(query)))

        match = re.search(r'"downloadUrl":"([^"]+)"', page)
        if match:
            try:
                return json.loads(f'"{match.group(1)}"')
            except json.JSONDecodeError:
                return (
                    match.group(1)
                    .replace(r"\/", "/")
                    .replace(r"\u003d", "=")
                    .replace(r"\u0026", "&")
                )
        return None
