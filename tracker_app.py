"""
iPhone dashboard web app.

The iPhone sends:
- JPEG camera frames
- bounding box coordinates
- hand gesture state
- generated G commands

The Mac webpage/server:
- displays the iPhone video feed
- displays iPhone metadata
- controls the Arduino over USB serial
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import threading
import time
from typing import Optional

from flask import Flask, Response, jsonify, render_template, request
from flask_sock import Sock

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
sock = Sock(app)


# ---------------------------------------------------------------------------
# Dynamixel serial controller
# ---------------------------------------------------------------------------

def list_serial_ports() -> list[dict]:
    """Return all available serial ports with name and description."""
    import serial.tools.list_ports

    ports = []

    for p in serial.tools.list_ports.comports():
        ports.append({
            "device": p.device,
            "description": p.description or p.device,
        })

    return sorted(ports, key=lambda p: p["device"])


def connect_to_port(port: str, baud: int = 115200, timeout: float = 2.0) -> bool:
    """
    Open the port, wait for the Arduino to boot, send 'R', and check for 'POS='.

    Returns True if it looks like the Arduino sketch is running.
    """
    import serial

    ser = serial.Serial(port, baud, timeout=1.0)

    time.sleep(timeout)
    ser.reset_input_buffer()
    ser.write(b"R\n")

    for _ in range(8):
        line = ser.readline().decode(errors="ignore").strip()

        if "POS=" in line:
            ser.close()
            return True

    ser.close()
    return False


class DynamixelController:
    def __init__(
        self,
        port: str,
        baud: int = 115200,
        angle_min: float = -10.0,
        angle_max: float = 10.0,
    ) -> None:
        import serial

        self._ser = serial.Serial(port, baud, timeout=0.1)
        self._angle_min = angle_min
        self._angle_max = angle_max
        self.port = port

        print(f"[SERVO] Connected on {port} at {baud} baud.")

    def goto(self, deg: float) -> None:
        deg = max(self._angle_min, min(self._angle_max, deg))
        self._ser.write(f"G{deg:.2f}\n".encode())

    def send_raw(self, command: str) -> None:
        command = command.strip()

        if not command:
            return

        self._ser.write((command + "\n").encode())

    def close(self) -> None:
        if self._ser.is_open:
            self._ser.close()
            print("[SERVO] Serial port closed.")


# ---------------------------------------------------------------------------
# Shared application state
# ---------------------------------------------------------------------------

class AppState:
    def __init__(self):
        self.lock = threading.Lock()

        # iPhone video stream
        self.latest_jpeg: Optional[bytes] = None
        self.frame_w: int = 0
        self.frame_h: int = 0

        # iPhone metadata
        self.iphone_connected: bool = False
        self.iphone_box = None
        self.iphone_g_command: str = ""
        self.iphone_hand_gesture: str = "none"
        self.iphone_last_gesture_event: str = "none"
        self.iphone_gesture_event_id: int = 0
        self.last_processed_gesture_event_id: int = 0
        self.iphone_timestamp: float = 0.0

        # Compatibility with existing UI fields
        self.tracking: bool = False
        self.paused: bool = False
        self.tracking_lost: bool = False
        self.box: Optional[tuple] = None
        self.proc_fps: float = 0.0
        self.status: str = "Waiting for iPhone"

        # Servo / Arduino serial
        self.servo: Optional[DynamixelController] = None
        self.servo_enabled: bool = True
        self.servo_angle: float = 0.0
        self.gain: float = 0.05
        self.deadzone_px: int = 30
        self.show_crosshair: bool = False
        self.last_sent_angle: float = 0.0
        self.min_angle_change: float = 0.3
        self.last_send_time: float = 0.0
        self.send_interval: float = 0.1

        # LED brightness shown in the UI.
        # Serial command may be inverted depending on your hardware.
        self.led_brightness: int = 50
        self.led_levels = [0, 25, 50, 75, 100]


state = AppState()


# ---------------------------------------------------------------------------
# iPhone message handling
# ---------------------------------------------------------------------------

def parse_g_command(command: str) -> Optional[float]:
    """
    Convert 'G-2.35' into -2.35.
    Returns None if the command is invalid.
    """
    command = (command or "").strip()

    if not command.lower().startswith("g"):
        return None

    try:
        return float(command[1:])
    except ValueError:
        return None


def maybe_forward_g_command_to_arduino(g_command: str) -> None:
    """
    Forward the iPhone-generated G command to the Arduino over serial
    if the servo is connected and movement is enabled.
    """
    angle = parse_g_command(g_command)

    if angle is None:
        return

    with state.lock:
        servo = state.servo
        servo_enabled = state.servo_enabled
        now = time.perf_counter()

        enough_time_elapsed = now - state.last_send_time >= state.send_interval
        enough_angle_change = abs(angle - state.last_sent_angle) >= state.min_angle_change

        if (
            servo is None
            or not servo_enabled
            or not enough_time_elapsed
            or not enough_angle_change
        ):
            return

        state.servo_angle = angle
        state.last_sent_angle = angle
        state.last_send_time = now

    try:
        servo.goto(angle)
        print(f"[SERVO] iPhone command forwarded: G{angle:.2f}")
    except Exception as e:
        print("[SERVO] Failed to forward G command:", e)


def cycle_led_from_iphone_gesture() -> None:
    """
    Cycle LED brightness when the iPhone sends an openPalm held gesture event.
    """
    with state.lock:
        current = state.led_brightness

        try:
            current_index = state.led_levels.index(current)
        except ValueError:
            current_index = 2

        next_index = (current_index + 1) % len(state.led_levels)
        next_brightness = state.led_levels[next_index]

        state.led_brightness = next_brightness
        servo = state.servo

    # Your existing /api/led route inverted brightness before sending to Arduino.
    # Keep that behavior here for consistency with your current hardware.
    serial_brightness = 100 - next_brightness

    if servo:
        try:
            servo.send_raw(f"L{serial_brightness}")
            print(f"[LED] Open palm -> UI {next_brightness}% / serial L{serial_brightness}")
        except Exception as e:
            print("[LED] Failed to send LED command:", e)


def process_iphone_gesture_event(event_id: int, gesture: str) -> None:
    """
    Process held gesture events once.
    thumbsUp toggles Mac-side motor movement forwarding.
    openPalm cycles LEDs through the Mac serial connection.
    """
    should_process = False

    with state.lock:
        if event_id != 0 and event_id != state.last_processed_gesture_event_id:
            state.last_processed_gesture_event_id = event_id
            should_process = True

    if not should_process:
        return

    if gesture == "thumbsUp":
        with state.lock:
            state.servo_enabled = not state.servo_enabled
            enabled = state.servo_enabled
            state.status = "Motor movement ON" if enabled else "Motor movement PAUSED"

        print(f"[GESTURE] thumbsUp -> servo_enabled={enabled}")

    elif gesture == "openPalm":
        print("[GESTURE] openPalm -> cycle LED brightness")
        cycle_led_from_iphone_gesture()


# ---------------------------------------------------------------------------
# WebSocket route for iPhone
# ---------------------------------------------------------------------------

@sock.route("/iphone")
def iphone_socket(ws):
    print("[IPHONE] Connected")

    with state.lock:
        state.iphone_connected = True
        state.status = "iPhone connected"

    try:
        while True:
            message = ws.receive()

            if message is None:
                break

            try:
                data = json.loads(message)
            except json.JSONDecodeError:
                print("[IPHONE] Invalid JSON")
                continue

            msg_type = data.get("type")

            if msg_type == "metadata":
                g_command = data.get("gCommand", "")
                hand_gesture = data.get("handGesture", "none")
                last_gesture_event = data.get("lastGestureEvent", "none")
                gesture_event_id = int(data.get("gestureEventID", 0) or 0)
                box = data.get("box")

                with state.lock:
                    state.iphone_g_command = g_command
                    state.iphone_hand_gesture = hand_gesture
                    state.iphone_last_gesture_event = last_gesture_event
                    state.iphone_gesture_event_id = gesture_event_id
                    state.iphone_box = box
                    state.iphone_timestamp = data.get("timestamp", time.time())

                    if box and state.frame_w and state.frame_h:
                        x = (box["x"] - box["width"] / 2.0) * state.frame_w
                        y = (box["y"] - box["height"] / 2.0) * state.frame_h
                        w = box["width"] * state.frame_w
                        h = box["height"] * state.frame_h
                        state.box = (x, y, w, h)
                    else:
                        state.box = None

                process_iphone_gesture_event(
                    event_id=gesture_event_id,
                    gesture=last_gesture_event,
                )

                maybe_forward_g_command_to_arduino(g_command)

            elif msg_type == "frame":
                image_b64 = data.get("imageBase64")

                if not image_b64:
                    continue

                try:
                    jpeg_bytes = base64.b64decode(image_b64)
                except Exception as e:
                    print("[IPHONE] Could not decode frame:", e)
                    continue

                frame_w = int(data.get("width", 0) or 0)
                frame_h = int(data.get("height", 0) or 0)

                with state.lock:
                    state.latest_jpeg = jpeg_bytes

                    if frame_w > 0:
                        state.frame_w = frame_w

                    if frame_h > 0:
                        state.frame_h = frame_h

                    state.status = "Receiving iPhone video"

    finally:
        print("[IPHONE] Disconnected")

        with state.lock:
            state.iphone_connected = False
            state.status = "iPhone disconnected"


# ---------------------------------------------------------------------------
# MJPEG stream generator
# ---------------------------------------------------------------------------

def generate_frames():
    while True:
        with state.lock:
            jpeg = state.latest_jpeg

        if jpeg:
            yield (
                b"--frame\r\n"
                b"Content-Type: image/jpeg\r\n\r\n" + jpeg + b"\r\n"
            )

        time.sleep(0.033)


# ---------------------------------------------------------------------------
# Flask routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/video_feed")
def video_feed():
    return Response(
        generate_frames(),
        mimetype="multipart/x-mixed-replace; boundary=frame",
    )


@app.route("/api/status")
def api_status():
    with state.lock:
        return jsonify({
            "status": state.status,
            "tracking": state.tracking,
            "paused": state.paused,
            "tracking_lost": state.tracking_lost,
            "fps": round(state.proc_fps, 1),
            "servo_enabled": state.servo_enabled,
            "servo_angle": round(state.servo_angle, 2),
            "gain": state.gain,
            "deadzone": state.deadzone_px,
            "frame_w": state.frame_w,
            "frame_h": state.frame_h,
            "servo_connected": state.servo is not None,
            "show_crosshair": state.show_crosshair,
            "led_brightness": state.led_brightness,
            "send_interval": state.send_interval,
            "box": list(state.box) if state.box else None,

            # iPhone dashboard fields
            "iphone_connected": state.iphone_connected,
            "iphone_g_command": state.iphone_g_command,
            "iphone_hand_gesture": state.iphone_hand_gesture,
            "iphone_last_gesture_event": state.iphone_last_gesture_event,
            "iphone_gesture_event_id": state.iphone_gesture_event_id,
            "iphone_motor_movement": "ON" if state.servo_enabled else "PAUSED",
            "iphone_box": state.iphone_box,
            "iphone_timestamp": state.iphone_timestamp,
        })


# ---------------------------------------------------------------------------
# Compatibility/no-op tracking routes
# ---------------------------------------------------------------------------

@app.route("/api/freeze", methods=["POST"])
def api_freeze():
    return jsonify({
        "ok": False,
        "error": "ROI tracking is disabled in iPhone dashboard mode."
    }), 400


@app.route("/api/resume", methods=["POST"])
def api_resume():
    return jsonify({"ok": True})


@app.route("/api/set_roi", methods=["POST"])
def api_set_roi():
    return jsonify({
        "ok": False,
        "error": "ROI tracking is disabled in iPhone dashboard mode."
    }), 400


@app.route("/api/reset", methods=["POST"])
def api_reset():
    with state.lock:
        state.box = None
        state.status = "Waiting for iPhone"
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Serial / Arduino routes
# ---------------------------------------------------------------------------

@app.route("/api/servo/list_ports")
def api_servo_list_ports():
    try:
        ports = list_serial_ports()

        with state.lock:
            connected_port = state.servo.port if state.servo else None

        return jsonify({
            "ok": True,
            "ports": ports,
            "connected": connected_port
        })

    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500


@app.route("/api/servo/connect", methods=["POST"])
def api_servo_connect():
    data = request.get_json()
    port = (data or {}).get("port")

    if not port:
        return jsonify({"ok": False, "error": "No port specified"}), 400

    with state.lock:
        old = state.servo
        state.servo = None

    if old:
        try:
            old.close()
        except Exception:
            pass

    try:
        verified = connect_to_port(port)
    except Exception as e:
        return jsonify({"ok": False, "error": f"Could not open {port}: {e}"}), 500

    if not verified:
        return jsonify({
            "ok": False,
            "error": (
                f"Port {port} opened but no Arduino response. "
                "Check the sketch is uploaded and baud rate is 115200."
            )
        }), 500

    try:
        controller = DynamixelController(port=port)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

    with state.lock:
        state.servo = controller
        state.servo_enabled = True
        state.status = "Arduino connected"

    # Ensure torque is on and set LEDs to default 50%.
    controller.send_raw("E")
    time.sleep(0.05)
    controller.send_raw("L50")

    print(f"[SERVO] Connected to Arduino on {port}")

    return jsonify({"ok": True, "port": port})


@app.route("/api/servo/disconnect", methods=["POST"])
def api_servo_disconnect():
    with state.lock:
        servo = state.servo
        state.servo = None

    if servo:
        try:
            servo.goto(0.0)
            time.sleep(0.5)
            servo.close()
        except Exception:
            pass

    with state.lock:
        state.status = "Arduino disconnected"

    return jsonify({"ok": True})


@app.route("/api/servo/home", methods=["POST"])
def api_servo_home():
    with state.lock:
        servo = state.servo

    if servo:
        servo.goto(0.0)

        with state.lock:
            state.servo_angle = 0.0
            state.last_sent_angle = 0.0

    return jsonify({"ok": True})


@app.route("/api/servo/toggle", methods=["POST"])
def api_servo_toggle():
    with state.lock:
        state.servo_enabled = not state.servo_enabled
        enabled = state.servo_enabled

    return jsonify({"ok": True, "servo_enabled": enabled})


@app.route("/api/led", methods=["POST"])
def api_led():
    data = request.get_json()

    try:
        pct = int(data["brightness"])
    except (KeyError, TypeError, ValueError) as e:
        return jsonify({"ok": False, "error": str(e)}), 400

    allowed = [0, 25, 50, 75, 100]
    pct = min(allowed, key=lambda v: abs(v - pct))

    # Keep behavior from your existing app: UI brightness is inverted for serial.
    serial_pct = 100 - pct

    with state.lock:
        servo = state.servo
        state.led_brightness = pct

    if servo:
        servo.send_raw(f"L{serial_pct}")
    else:
        return jsonify({"ok": False, "error": "Arduino not connected"}), 400

    return jsonify({"ok": True, "brightness": pct})


@app.route("/api/toggle_crosshair", methods=["POST"])
def api_toggle_crosshair():
    with state.lock:
        state.show_crosshair = not state.show_crosshair
        visible = state.show_crosshair

    return jsonify({"ok": True, "show_crosshair": visible})


@app.route("/api/settings", methods=["POST"])
def api_settings():
    data = request.get_json()

    with state.lock:
        if "gain" in data:
            state.gain = float(data["gain"])

        if "deadzone" in data:
            state.deadzone_px = int(data["deadzone"])

        if "send_interval" in data:
            state.send_interval = float(data["send_interval"])

        if "min_angle_change" in data:
            state.min_angle_change = float(data["min_angle_change"])

    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="iPhone dashboard web app")
    parser.add_argument(
        "--port",
        type=int,
        default=8080,
        help="Flask port (default: 8080)"
    )

    args = parser.parse_args()

    print(f"\n  Open http://localhost:{args.port} in your browser")
    print(f"  iPhone WebSocket endpoint: ws://<MAC_IP>:{args.port}/iphone\n")

    try:
        app.run(host="0.0.0.0", port=args.port, debug=False, threaded=True)
    finally:
        with state.lock:
            servo = state.servo

        if servo:
            print("[SERVO] Returning to home...")
            servo.goto(0.0)
            time.sleep(0.5)
            servo.close()


if __name__ == "__main__":
    main()
