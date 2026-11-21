"""CaptureKit Scan Bundle v1.x -> SourceDataset (the real phone bundle, not the v0.1 proposal).

Spec: `2D-3D/capturekit/spec/scanbundle/SPEC.md` (read-only contract). A bundle is a folder or one
`.zip` holding `manifest.json`, `camera.json`, `streams.mcap` (Protobuf channels) and
`keyframes/*.jpg`. Conventions fixed by the spec and checked here: world Y-up gravity-aligned in
metres, camera OPENCV (x right, y down, z forward: no axis flip), pose T_world_from_camera,
quaternions stored w,x,y,z on disk (scipy wants x,y,z,w: converted once, in `_slerp`).

Device poses become *priors* (never ground truth). Mapping, mirrored from
`ckit.convert.colmap.load_keyframe_poses`: keyframes are the `/frame_index` records with
`keyframe` and a `file`; poses are the `/pose` records with tracking NORMAL, interpolated at each
keyframe `t_ns` (no extrapolation, bracket gap <= 100 ms; keyframes without one are skipped and
counted); intrinsics are the latest `/intrinsics` at or before `t_ns`, else `camera.json`.

SourceDataset has one K: the first keyframe's. A later keyframe whose width, height, fx or fy
differs by more than 0.5 % raises `CaptureKitBundleError`; smaller drift is recorded in the notes.
The IMU is not mapped (ADR 0034: nothing downstream reads it).

`gravity_source` is "arkit" for iOS bundles and "dataset_axis" otherwise: the priors enum has no
"arcore" value (formats/models.py), and the bundle's gravity is the frozen Y-up world axis.
`device_pose_source` is "arkit" for iOS and "arcore" for every other platform (android, and
synthetic test bundles), the two values the priors enum offers for device poses.
"""

from __future__ import annotations

import atexit
import bisect
import json
import shutil
import tempfile
import zipfile
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation, Slerp

from spatial.io.adapters import SourceDataset, SourceFrame

SUPPORTED_MAJOR = 1
KNOWN_MINOR_MAX = 4  # SPEC.md "Versioning": 1.4.0 is the newest this reader was written against
MAX_GAP_NS = 100_000_000
INTRINSICS_TOL = 0.005
TRACKING_NORMAL = 1
CAMERA_MODEL_OPENCV = 1
MAX_ENTRIES = 20_000
MAX_UNPACKED_BYTES = 4 * 1024**3
FREE_SPACE_MARGIN = 1.1
_S_IFMT, _S_IFLNK = 0o170000, 0o120000
_CONVENTIONS = {
    "world": "Y_UP_GRAVITY_METRES",
    "camera": "OPENCV",
    "quaternion": "WXYZ",
    "pose": "T_WORLD_FROM_CAMERA",
}

_message_classes: dict[tuple[bytes, str], type] = {}


class CaptureKitBundleError(ValueError):
    """The bundle is unreadable, unsupported or unsafe."""


# --------------------------------------------------------------------------- zip handling
def _unsafe_name(name: str) -> bool:
    """A name that could escape the extraction folder or is not a plain relative path."""
    if not name or "\\" in name or "\x00" in name or name.startswith("/"):
        return True
    return any(":" in p or p in ("", ".", "..") for p in name.split("/"))


def _extract_zip(path: Path, dest: Path) -> Path:
    """Unpack `path` into `dest`, refusing what SPEC.md "Archive form" says to refuse."""
    try:
        zf = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as e:
        raise CaptureKitBundleError(f"{path}: not a readable zip: {e}") from e
    with zf:
        infos = [i for i in zf.infolist() if not i.is_dir()]
        if len(infos) > MAX_ENTRIES:
            raise CaptureKitBundleError(f"{path}: more than {MAX_ENTRIES} entries")
        total = sum(i.file_size for i in infos)
        if total > MAX_UNPACKED_BYTES:
            raise CaptureKitBundleError(f"{path}: unpacks to more than {MAX_UNPACKED_BYTES} bytes")
        names = [i.filename for i in infos]
        if len({n.casefold() for n in names}) != len(names):
            raise CaptureKitBundleError(f"{path}: duplicate entry names")
        for i in infos:  # check every name before writing anything
            if _unsafe_name(i.filename) or (i.external_attr >> 16) & _S_IFMT == _S_IFLNK:
                raise CaptureKitBundleError(f"{path}: unsafe entry {i.filename!r}")
        probe = next(p for p in (dest, *dest.parents) if p.exists())
        if total * FREE_SPACE_MARGIN > shutil.disk_usage(probe).free:
            raise CaptureKitBundleError(f"{path}: not enough free space to unpack it")
        dest.mkdir(parents=True, exist_ok=True)
        root = dest.resolve()
        for info in infos:
            target = (root / info.filename).resolve()
            if root not in target.parents:
                raise CaptureKitBundleError(f"{path}: entry escapes the folder: {info.filename!r}")
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info) as fin, target.open("wb") as fout:
                    shutil.copyfileobj(fin, fout, 1 << 20)
            except (zipfile.BadZipFile, EOFError, OSError, ValueError) as e:
                raise CaptureKitBundleError(f"{path}: cannot read {info.filename}: {e}") from e
    return dest


def _open_bundle(root: Path) -> Path:
    """The bundle as a folder: `root` itself, or a temporary copy unpacked from a `.zip`."""
    if root.is_file() and root.suffix.lower() == ".zip":
        tmp = Path(tempfile.mkdtemp(prefix="capturekit-bundle-"))
        atexit.register(shutil.rmtree, tmp, ignore_errors=True)
        try:
            return _extract_zip(root, tmp / root.stem)
        except CaptureKitBundleError:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
    if not root.is_dir():
        raise CaptureKitBundleError(f"{root}: not a bundle folder or .zip")
    return root


# --------------------------------------------------------------------------- MCAP
def _message_class(schema_data: bytes, name: str):
    """Message class from the FileDescriptorSet embedded in the file (both protobuf APIs)."""
    from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

    key = (schema_data, name)
    if key not in _message_classes:
        fds = descriptor_pb2.FileDescriptorSet.FromString(schema_data)
        pool = descriptor_pool.DescriptorPool()
        for fd in fds.file:
            pool.Add(fd)
        desc = pool.FindMessageTypeByName(name)
        get = getattr(message_factory, "GetMessageClass", None)
        _message_classes[key] = (
            get(desc) if get else message_factory.MessageFactory(pool).GetPrototype(desc)
        )
    return _message_classes[key]


def _read_topics(path: Path, topics: list[str]) -> dict[str, list]:
    from mcap.reader import make_reader

    out: dict[str, list] = {t: [] for t in topics}
    try:
        with open(path, "rb") as f:
            for schema, channel, message in make_reader(f).iter_messages(topics=topics):
                if schema is None:
                    raise CaptureKitBundleError(f"{path}: channel {channel.topic} has no schema")
                cls = _message_class(schema.data, schema.name)
                out[channel.topic].append(cls.FromString(message.data))
    except CaptureKitBundleError:
        raise
    except Exception as e:  # noqa: BLE001 - any parse failure means an unreadable stream
        raise CaptureKitBundleError(f"{path}: cannot read MCAP: {type(e).__name__}: {e}") from e
    return out


# --------------------------------------------------------------------------- poses
def _slerp(t_a, q_a, t_b, q_b, t) -> tuple[np.ndarray, np.ndarray]:
    """Interpolate between two w,x,y,z poses; returns (translation, 3x3 rotation)."""
    a = (t - t_a[0]) / (t_b[0] - t_a[0])
    rots = Rotation.from_quat([_wxyz_to_xyzw(q_a), _wxyz_to_xyzw(q_b)])
    r = Slerp([0.0, 1.0], rots)(a).as_matrix()
    return (1 - a) * np.asarray(t_a[1]) + a * np.asarray(t_b[1]), r


def _wxyz_to_xyzw(q) -> list[float]:
    w, x, y, z = q
    n = (w * w + x * x + y * y + z * z) ** 0.5
    if not n > 0:
        raise CaptureKitBundleError("pose with a zero quaternion")
    return [x / n, y / n, z / n, w / n]


def _pose_at(ts: list[int], poses: list, t_ns: int) -> np.ndarray | None:
    """T_world_from_camera at `t_ns`, interpolated; None outside the track or across a gap.

    Same rule as the core's PoseTrack::interpolate_at.
    """
    if not ts or t_ns < ts[0] or t_ns > ts[-1]:
        return None
    i = bisect.bisect_left(ts, t_ns)
    if ts[i] == t_ns:
        t, r = _tq(poses[i])[0], Rotation.from_quat(_wxyz_to_xyzw(_tq(poses[i])[1])).as_matrix()
    else:
        if ts[i] - ts[i - 1] > MAX_GAP_NS:
            return None
        pa, pb = _tq(poses[i - 1]), _tq(poses[i])
        t, r = _slerp((ts[i - 1], pa[0]), pa[1], (ts[i], pb[0]), pb[1], t_ns)
    T = np.eye(4)
    T[:3, :3] = r
    T[:3, 3] = t
    return T


def _tq(p) -> tuple[list[float], list[float]]:
    return [p.tx, p.ty, p.tz], [p.qw, p.qx, p.qy, p.qz]


# --------------------------------------------------------------------------- loader
def _intr_dict(m) -> dict:
    return {
        "width": int(m.width),
        "height": int(m.height),
        "fx": float(m.fx),
        "fy": float(m.fy),
        "cx": float(m.cx),
        "cy": float(m.cy),
        "opencv": int(m.model) == CAMERA_MODEL_OPENCV,
        "distortion": [float(d) for d in m.distortion],
    }


def _check_manifest(man: dict, root: Path) -> tuple[str, int]:
    ver = str(man.get("schema_version", ""))
    try:
        major, minor, _ = (int(x) for x in ver.split("."))
    except ValueError as e:
        raise CaptureKitBundleError(f"{root}: bad schema_version {ver!r}") from e
    if major != SUPPORTED_MAJOR:
        raise CaptureKitBundleError(f"{root}: schema_version {ver}: only major 1 is supported")
    conv = man.get("conventions", {})
    for key, want in _CONVENTIONS.items():
        if conv.get(key) != want:
            raise CaptureKitBundleError(
                f"{root}: conventions.{key} is {conv.get(key)!r}, not {want}"
            )
    for key in ("bundle_id", "device"):
        if key not in man:
            raise CaptureKitBundleError(f"{root}: manifest.json has no {key}")
    return ver, minor


def load_capturekit(root: Path) -> SourceDataset:
    """Load a Scan Bundle v1.x (folder or `.zip`) as a SourceDataset with device-pose priors."""
    folder = _open_bundle(Path(root))
    try:
        man = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise CaptureKitBundleError(f"{root}: cannot read manifest.json: {e}") from e
    ver, minor = _check_manifest(man, root)
    platform = str(man["device"].get("platform", "other"))

    streams = _read_topics(folder / "streams.mcap", ["/pose", "/intrinsics", "/frame_index"])
    poses = sorted(
        (p for p in streams["/pose"] if p.tracking_state == TRACKING_NORMAL), key=lambda p: p.t_ns
    )
    pose_ts = [p.t_ns for p in poses]
    if streams["/intrinsics"]:
        intr = sorted(((m.t_ns, _intr_dict(m)) for m in streams["/intrinsics"]), key=lambda x: x[0])
    else:
        cam = json.loads((folder / "camera.json").read_text(encoding="utf-8"))
        intr = [
            (
                0,
                {
                    **{k: cam[k] for k in ("width", "height", "fx", "fy", "cx", "cy")},
                    "opencv": cam.get("model") == "OPENCV",
                    "distortion": [float(d) for d in cam.get("distortion", [])],
                },
            )
        ]
    intr_ts = [t for t, _ in intr]

    kf = sorted((f for f in streams["/frame_index"] if f.keyframe and f.file), key=lambda f: f.t_ns)
    frames: list[SourceFrame] = []
    Ks: list[dict] = []
    skipped = 0
    for f in kf:
        T = _pose_at(pose_ts, poses, f.t_ns)
        if T is None:
            skipped += 1
            continue
        rgb = folder / f.file
        if (
            _unsafe_name(f.file)
            or not rgb.is_file()
            or folder.resolve() not in rgb.resolve().parents
        ):
            raise CaptureKitBundleError(f"{root}: keyframe file {f.file!r} is missing or unsafe")
        Ks.append(intr[max(0, bisect.bisect_right(intr_ts, f.t_ns) - 1)][1])
        frames.append(
            SourceFrame(
                index=len(frames),
                timestamp_ns=int(f.t_ns),
                rgb=rgb,
                depth=None,
                T_world_camera_gt=None,
                T_world_camera_device=T,
            )
        )
    if not frames:
        raise CaptureKitBundleError(f"{root}: no keyframe has a tracked pose ({skipped} skipped)")

    first = Ks[0]
    for k in Ks:
        if min(k["fx"], k["fy"], k["width"], k["height"]) <= 0:
            raise CaptureKitBundleError(f"{root}: non-positive fx, fy, width or height")
    worst = 0.0
    for k in Ks[1:]:
        if k["opencv"] != first["opencv"]:
            raise CaptureKitBundleError(f"{root}: the camera model changes between keyframes")
        for key in ("width", "height", "fx", "fy"):
            worst = max(worst, abs(k[key] - first[key]) / abs(first[key]))
    if worst > INTRINSICS_TOL:
        raise CaptureKitBundleError(
            f"{root}: intrinsics vary by {worst:.2%} between keyframes "
            f"(limit {INTRINSICS_TOL:.1%}); SourceDataset holds one K"
        )

    K = np.array([[first["fx"], 0, first["cx"]], [0, first["fy"], first["cy"]], [0, 0, 1.0]])
    dist = np.asarray(first["distortion"], float) if first["opencv"] else None
    if dist is not None and not np.any(dist):  # empty or all zeros: already a pinhole
        dist = None
    ios = platform == "ios"
    notes = [
        f"capturekit bundle schema {ver}, device {man['device'].get('model', '?')} ({platform})",
        f"{skipped} keyframes skipped: no tracked pose within {MAX_GAP_NS // 1_000_000} ms",
        "intrinsics: first keyframe's K for all frames"
        + (f"; varied by up to {worst:.3%}" if worst > 0 else ""),
        "IMU not mapped (ADR 0034)",
    ]
    if minor > KNOWN_MINOR_MAX:
        notes.append(f"minor version {minor} is newer than 1.{KNOWN_MINOR_MAX}: read as 1.x")
    if platform not in ("ios", "android"):
        notes.append(f"platform {platform!r}: device poses labelled arcore")
    return SourceDataset(
        name="capturekit",
        scene=str(man["bundle_id"]),
        root=folder,
        width=int(first["width"]),
        height=int(first["height"]),
        K=K,
        dist=dist,
        depth_scale_m=None,
        depth_source="none",
        frames=frames,
        gravity_world_gt=np.array([0.0, -1.0, 0.0]),
        gravity_source="arkit" if ios else "dataset_axis",
        gt_geometry=None,
        has_gt=False,
        device_pose_source="arkit" if ios else "arcore",
        notes=notes,
    )
