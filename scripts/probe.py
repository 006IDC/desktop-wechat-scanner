#!/usr/bin/env python3
"""Bounded, reversible check: a Mac QR window reaches this phone's virtual camera.

Run only after scripts/bootstrap.py and scripts/build.py. This deliberately does
not open WeChat or scan a real account, payment, or login code.
"""

from __future__ import annotations

import argparse
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ADB = ROOT / ".tools/sdk/platform-tools/adb"
QR = ROOT / "build/qr-helper"
DESKTOP = ROOT / "build/desktop-source"
JAR = ROOT / "build/camera-probe.jar"
APK = ROOT / "build/qr-self-test.apk"
PHONE_DIR = "/data/local/tmp/006idc-qr-probe"
PACKAGE = "com.idc006.qrprobe"
MAC = "02:00:00:06:10:25"
PROFILE = "android.app.role.COMPANION_DEVICE_APP_STREAMING"
ASSOCIATION = re.compile(
    r"^\s*(\d+)\s*\|\s*com\.android\.shell\s*\|\s*02:00:00:06:10:25\s*$",
    re.MULTILINE,
)
FIELD = re.compile(r"^QR_PROBE (device_id|display_id|ready|error)=(.*)$")


class ProbeError(RuntimeError):
    pass


def execute(argv: list[str], *, timeout: int = 20, check: bool = True,
            binary: bool = False) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(argv, capture_output=True, text=not binary,
                                timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise ProbeError(f"命令超时（{timeout} 秒）：{argv[0]} {argv[1:3]}") from exc
    if check and result.returncode:
        err = result.stderr or result.stdout
        if isinstance(err, bytes):
            err = err.decode("utf-8", errors="replace")
        raise ProbeError(f"命令失败（{result.returncode}）：{str(err).strip()[:600]}")
    return result


def adb(*args: str, timeout: int = 20, check: bool = True,
        binary: bool = False) -> subprocess.CompletedProcess:
    return execute([str(ADB), "-d", *args], timeout=timeout, check=check,
                   binary=binary)


def phone_shell(command: str, *, timeout: int = 20,
                check: bool = True) -> subprocess.CompletedProcess:
    return adb("shell", command, timeout=timeout, check=check)


def association_ids(output: str) -> list[int]:
    return [int(value) for value in ASSOCIATION.findall(output)]


def check_prerequisites() -> None:
    for path in (ADB, QR, DESKTOP, JAR, APK):
        if not path.is_file():
            raise ProbeError(f"缺少 {path.relative_to(ROOT)}；请先运行 bootstrap/build 并编译 Swift 工具")
    if adb("get-state").stdout.strip() != "device":
        raise ProbeError("需要且仅允许一台已授权的 USB Android 手机")
    exists = phone_shell(f"test -e {PHONE_DIR}", check=False)
    if exists.returncode == 0:
        raise ProbeError(f"手机上已有 {PHONE_DIR}，为避免覆盖数据已停止")
    if exists.returncode != 1:
        raise ProbeError("无法确认手机测试目录是否已存在")
    listing = phone_shell("cmd companiondevice list 0").stdout
    if association_ids(listing):
        raise ProbeError(f"已存在测试 MAC {MAC} 的关联，已停止以免修改已有关联")
    package_path = phone_shell(f"pm path {PACKAGE}",check=False)
    if package_path.returncode not in (0,1):
        raise ProbeError("无法确认测试包是否已存在")
    if "package:" in package_path.stdout:
        raise ProbeError(f"测试包 {PACKAGE} 已存在，已停止以免覆盖")


def read_server(process: subprocess.Popen, messages: queue.Queue[str]) -> None:
    assert process.stdout is not None
    for line in process.stdout:
        messages.put(line.rstrip("\r\n"))
    messages.put("<SERVER_EXIT>")


def await_server(process: subprocess.Popen, messages: queue.Queue[str]) -> tuple[int, int]:
    values: dict[str, str] = {}
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            line = messages.get(timeout=min(1, deadline - time.monotonic()))
        except queue.Empty:
            continue
        match = FIELD.match(line)
        if match:
            values[match.group(1)] = match.group(2)
            if match.group(1) == "error":
                raise ProbeError(f"手机虚拟设备创建失败：{match.group(2)}")
            if values.get("ready") == "virtual_camera_and_display":
                try:
                    device_id = int(values["device_id"])
                    display_id = int(values["display_id"])
                except (KeyError, ValueError) as exc:
                    raise ProbeError("虚拟设备日志缺少有效设备/显示 ID") from exc
                if device_id <= 0 or display_id <= 0:
                    raise ProbeError("虚拟设备返回了无效 ID")
                return device_id, display_id
        if line == "<SERVER_EXIT>" or process.poll() is not None:
            raise ProbeError("虚拟设备进程在就绪前退出：" + line[:400])
    raise ProbeError("等待虚拟相机和显示器就绪超时")


def await_capture(timeout: int = 30) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = phone_shell(f"run-as {PACKAGE} cat files/result.txt", check=False)
        report = result.stdout.strip()
        if report.startswith("CAPTURED:"):
            return report
        if report.startswith(("FAILED:", "ERROR:", "REFUSED:")):
            raise ProbeError("测试 App 相机采集失败：" + report[:500])
        time.sleep(0.5)
    raise ProbeError("等待测试 App 的相机帧超时")


def self_test(state: dict[str, object]) -> None:
    check_prerequisites()
    (ROOT / ".local").mkdir(exist_ok=True)
    local_dir = Path(tempfile.mkdtemp(prefix="probe-run-", dir=ROOT / ".local"))
    payload = "006IDC-DESKTOP-QR-TEST-" + uuid.uuid4().hex.upper()
    qr_file = local_dir / "source-qr.png"
    desktop_file = local_dir / "desktop-captured.png"
    readback_file = local_dir / "camera-readback.jpg"

    execute([str(QR), "make", str(qr_file), payload], timeout=20)
    desktop = execute([str(DESKTOP), str(qr_file), str(desktop_file)], timeout=90)
    if "CAPTURED window_id=" not in desktop.stdout or not desktop_file.is_file():
        raise ProbeError("Mac 工具没有报告成功捕获自己的二维码窗口")
    decoded = execute([str(QR), "read", str(desktop_file)], timeout=20).stdout.strip()
    if decoded != payload:
        raise ProbeError("Mac 窗口截图中的二维码内容与生成值不一致")

    phone_shell(f"mkdir {PHONE_DIR}")
    state["directory_created"] = True
    before = phone_shell("cmd companiondevice list 0").stdout
    before_ids = association_ids(before)
    if before_ids:
        raise ProbeError("创建前检测到相同 MAC 的关联，停止")
    phone_shell(f"cmd companiondevice associate 0 com.android.shell {MAC} {PROFILE}")
    state["association_created"] = True
    after = phone_shell("cmd companiondevice list 0").stdout
    ids = association_ids(after)
    if len(ids) != 1 or ids[0] <= 0:
        raise ProbeError("无法从新关联的包名和 MAC 精确解析 association ID")
    assoc_id = ids[0]
    state["association_id"] = assoc_id

    adb("push", str(desktop_file), f"{PHONE_DIR}/test-qr.png", timeout=30)
    adb("push", str(JAR), f"{PHONE_DIR}/camera-probe.jar", timeout=30)
    state["install_attempted"] = True
    adb("install", "--no-incremental", str(APK), timeout=90)

    command = (f"CLASSPATH={PHONE_DIR}/camera-probe.jar "
               f"app_process / CameraProbe serve {assoc_id} 120")
    process = subprocess.Popen([str(ADB), "-d", "shell", command],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1)
    state["server"] = process
    messages: queue.Queue[str] = queue.Queue()
    threading.Thread(target=read_server, args=(process, messages), daemon=True).start()
    device_id, display_id = await_server(process, messages)
    state["device_id"] = device_id
    state["grant_attempted"] = True
    phone_shell(f"CLASSPATH={PHONE_DIR}/camera-probe.jar "
                f"app_process / GrantProbe {device_id} {PACKAGE}")
    launched = phone_shell(
        f"am start --display {display_id} -n {PACKAGE}/.SelfTestActivity "
        f"--ei deviceId {device_id}").stdout
    if "Error:" in launched or "Exception" in launched:
        raise ProbeError("无法在虚拟显示器启动测试 App：" + launched[:500])
    report = await_capture()
    image = adb("exec-out", "run-as", PACKAGE, "cat", "files/readback.jpg",
                timeout=20, binary=True).stdout
    if not image.startswith(b"\xff\xd8"):
        raise ProbeError("从测试 App 私有目录读出的内容不是 JPEG 帧")
    readback_file.write_bytes(image)
    decoded = execute([str(QR), "read", str(readback_file)], timeout=20).stdout.strip()
    if decoded != payload:
        raise ProbeError("手机虚拟相机读回的二维码与 Mac 窗口像素不一致")
    print(f"PASS {report}; Mac 窗口截图与手机相机帧均解码为同一测试文本。")
    print(f"本地测试图像：{local_dir}")


def cleanup(state: dict[str, object]) -> list[str]:
    problems: list[str] = []

    def try_step(label: str, command: str, *, timeout: int = 15) -> None:
        try:
            phone_shell(command, timeout=timeout)
        except (ProbeError, OSError) as exc:
            problems.append(f"{label} 未完成：{exc}。待手机重连后执行：adb -d shell '{command}'")

    device_id = state.get("device_id")
    if state.get("grant_attempted") and isinstance(device_id, int):
        try_step("撤销测试虚拟设备的相机授权",
                 f"CLASSPATH={PHONE_DIR}/camera-probe.jar "
                 f"app_process / GrantProbe {device_id} {PACKAGE} revoke")
    server = state.get("server")
    if isinstance(server, subprocess.Popen):
        try_step("停止测试服务", f"touch {PHONE_DIR}/stop")
        try:
            server.wait(timeout=12)
        except subprocess.TimeoutExpired:
            server.terminate()  # Ends this host ADB transport; phone service also has 120 s limit.
            problems.append("测试服务未及时退出；手机端最长 120 秒自动结束，重连后检查测试目录")
    if state.get("install_attempted"):
        try:
            listing=phone_shell(f"cmd package list packages {PACKAGE}").stdout
            if f"package:{PACKAGE}" in listing.splitlines():
                adb("uninstall", PACKAGE, timeout=30)
        except (ProbeError, OSError) as exc:
            problems.append(f"卸载本次测试 App 未完成：{exc}。待重连后执行：adb -d uninstall {PACKAGE}")
    if state.get("association_created"):
        try_step("移除本次 companion 关联",
                 f"cmd companiondevice disassociate 0 com.android.shell {MAC}")
    if state.get("directory_created"):
        files = ("test-qr.png", "camera-probe.jar", "stop", "snapshot",
                 "display.png", "display.png.tmp")
        paths = " ".join(f"{PHONE_DIR}/{name}" for name in files)
        try_step("移除本次测试文件", f"rm -f {paths}")
        try_step("移除本次空目录", f"rmdir {PHONE_DIR}")
    if state:
        try:
            if state.get("directory_created"):
                phone_shell(f"test ! -e {PHONE_DIR}")
            if state.get("association_created") and association_ids(phone_shell("cmd companiondevice list 0").stdout):
                raise ProbeError("测试关联仍存在")
            if state.get("install_attempted") and f"package:{PACKAGE}" in phone_shell(f"cmd package list packages {PACKAGE}").stdout.splitlines():
                raise ProbeError("测试 App 仍存在")
        except (ProbeError,OSError) as exc:
            problems.append(f"清理回读未通过：{exc}；请重新连接原手机核对本次测试资源")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", required=True,
                        help="真实 Mac 窗口→小米虚拟相机→测试 App 的纯文本二维码验证")
    parser.parse_args()
    state: dict[str, object] = {}
    result = 0
    try:
        self_test(state)
    except (ProbeError, OSError) as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        result = 1
    finally:
        problems = cleanup(state)
        if problems:
            result = 1
            for problem in problems:
                print("CLEANUP " + problem, file=sys.stderr)
        elif any(state.values()):
            print("CLEANUP 手机端本次创建的测试资源已清理")
    return result


if __name__ == "__main__":
    sys.exit(main())
