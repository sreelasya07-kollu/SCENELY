"""CaptureKit Scan Bundle v1.x loader (spatial/io/capturekit.py) on the frozen 1.0.0 example.

The example has 120 poses, the first 30 with tracking LIMITED, and 20 keyframes at multiples of
100 ms; the 5 keyframes before the first NORMAL pose have no bracket and are skipped, so 15
frames remain (the same rule as `ckit export-colmap`).
"""

from __future__ import annotations

import json
import shutil
import zipfile
from pathlib import Path

import numpy as np
import pytest

from spatial.io.adapters import LOADERS
from spatial.io.capturekit import CaptureKitBundleError, _read_topics, load_capturekit

FROZEN = (
    Path(__file__).resolve().parents[2] / "2D-3D/capturekit/spec/scanbundle/examples/frozen-1.0.0"
)
pytestmark = [
    pytest.mark.light,
    pytest.mark.skipif(not (FROZEN / "manifest.json").exists(), reason="frozen-1.0.0 not present"),
]
N_KEYFRAMES, N_SKIPPED = 20, 5


@pytest.fixture(scope="module")
def ds():
    return load_capturekit(FROZEN)


def _copy(tmp_path) -> Path:
    dst = tmp_path / "bundle"
    shutil.copytree(FROZEN, dst)
    return dst


def test_registered_loader():
    assert LOADERS["capturekit"] is not None


def test_frames_and_conventions(ds):
    assert len(ds.frames) == N_KEYFRAMES - N_SKIPPED
    assert any(f"{N_SKIPPED} keyframes skipped" in n for n in ds.notes)
    assert ds.name == "capturekit" and ds.scene == "06fb2603-ce03-5cdd-afab-0a3b03339e44"
    assert not ds.has_gt and ds.depth_source == "none" and ds.dist is None
    assert (ds.width, ds.height) == (640, 480)
    assert ds.K[0, 0] == 500 and ds.K[0, 2] == 319.5
    assert np.allclose(ds.gravity_world_gt, [0, -1, 0])
    assert ds.device_pose_source == "arcore" and ds.gravity_source == "dataset_axis"
    assert all(f.rgb.is_file() and f.T_world_camera_gt is None for f in ds.frames)


def test_poses_are_rigid(ds):
    for f in ds.frames:
        T = f.T_world_camera_device
        assert T.shape == (4, 4) and np.allclose(T[3], [0, 0, 0, 1])
        R = T[:3, :3]
        assert np.allclose(R.T @ R, np.eye(3), atol=1e-9)
        assert np.isclose(np.linalg.det(R), 1.0, atol=1e-9)


def test_camera_z_matches_hand_computed_quaternion(ds):
    """Keyframe times coincide with /pose records: the pose must be that record, w,x,y,z order."""
    f = ds.frames[len(ds.frames) // 2]
    streams = _read_topics(FROZEN / "streams.mcap", ["/pose"])
    p = next(m for m in streams["/pose"] if m.t_ns == f.timestamp_ns and m.tracking_state == 1)
    w, x, y, z = p.qw, p.qx, p.qy, p.qz
    n = (w * w + x * x + y * y + z * z) ** 0.5
    w, x, y, z = w / n, x / n, y / n, z / n
    z_axis = [2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)]
    T = f.T_world_camera_device
    assert np.allclose(T[:3, 2], z_axis, atol=1e-9)  # OPENCV camera: +Z forward, no flip
    assert np.allclose(T[:3, 3], [p.tx, p.ty, p.tz])


def test_zip_form_loads(tmp_path):
    z = tmp_path / "b.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.write(FROZEN / "manifest.json", "manifest.json")
        for rel in ("camera.json", "streams.mcap"):
            zf.write(FROZEN / rel, rel)
        for jpg in sorted((FROZEN / "keyframes").glob("*.jpg")):
            zf.write(jpg, f"keyframes/{jpg.name}")
    ds = load_capturekit(z)
    assert len(ds.frames) == N_KEYFRAMES - N_SKIPPED and ds.frames[0].rgb.is_file()


def test_major_2_rejected(tmp_path):
    b = _copy(tmp_path)
    man = json.loads((b / "manifest.json").read_text())
    man["schema_version"] = "2.0.0"
    (b / "manifest.json").write_text(json.dumps(man))
    with pytest.raises(CaptureKitBundleError, match="major 1"):
        load_capturekit(b)


def test_zip_with_dotdot_rejected(tmp_path):
    z = tmp_path / "evil.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.write(FROZEN / "manifest.json", "manifest.json")
        zf.writestr("../evil.txt", "x")
    with pytest.raises(CaptureKitBundleError, match="unsafe"):
        load_capturekit(z)
    assert not (tmp_path.parent / "evil.txt").exists()


def test_non_positive_intrinsics_rejected(monkeypatch):
    import spatial.io.capturekit as ck

    real = ck._read_topics

    def broken(path, topics):
        out = real(path, topics)
        for m in out["/intrinsics"]:
            m.fx = 0.0
        return out

    monkeypatch.setattr(ck, "_read_topics", broken)
    with pytest.raises(CaptureKitBundleError, match="non-positive"):
        load_capturekit(FROZEN)
