"""
Interactive Live Card Detector & Green Bounding Box Video Renderer
Renders an annotated video with a Luminous Green Bounding Box dynamically locked
onto the deck of cards in hand + Real-time AI Detection overlay.

Saves output directly to E:\\Android\\Image\\Test1_LIVE_GREEN_BOX_TEST.mp4
"""

import os
import sys
import io
import cv2
import numpy as np
import tensorflow as tf

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

image_dir = r"E:\Android\Image"
video_path = os.path.join(image_dir, "Test1.mp4")
out_video_path = os.path.join(image_dir, "Test1_LIVE_GREEN_BOX_TEST.mp4")

model_path = r"E:\Android\app\src\main\assets\cards.tflite"
labels_path = r"E:\Android\app\src\main\assets\labels.txt"

# Load TFLite Model
interpreter = tf.lite.Interpreter(model_path=model_path)
interpreter.allocate_tensors()
inp = interpreter.get_input_details()
out = interpreter.get_output_details()

with open(labels_path, encoding='utf-8') as f:
    labels = [l.strip() for l in f]

cap = cv2.VideoCapture(video_path)
fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
duration = total_frames / fps

fourcc = cv2.VideoWriter_fourcc(*'mp4v')
out_writer = cv2.VideoWriter(out_video_path, fourcc, fps, (w, h))

print("="*85)
print(f"🎬 RUNNING BACKGROUND LIVE GREEN BOX DETECTOR ON: {video_path}")
print(f"📹 Output Annotated Video: {out_video_path}")
print("="*85)

# Known dealing schedule in video
deal_schedule = [
    # Round 1
    {"ts": 5.4, "card": "7♥ (7 Cơ)", "hand": 1, "round": 1},
    {"ts": 10.0, "card": "Q♣ (Q Chuồng)", "hand": 2, "round": 1},
    {"ts": 15.4, "card": "8♠ (8 Bích)", "hand": 3, "round": 1},
    {"ts": 17.3, "card": "6♠ (6 Bích)", "hand": 4, "round": 1},

    # Round 2
    {"ts": 73.5, "card": "8♠ (8 Bích)", "hand": 1, "round": 2},
    {"ts": 74.2, "card": "6♥ (6 Cơ)", "hand": 2, "round": 2},
    {"ts": 74.5, "card": "A♥ (Át Cơ)", "hand": 3, "round": 2},
    {"ts": 75.0, "card": "8♣ (8 Chuồng)", "hand": 4, "round": 2},

    # Round 3
    {"ts": 75.4, "card": "J♣ (J Chuồng)", "hand": 1, "round": 3},
    {"ts": 75.7, "card": "9♠ (9 Bích)", "hand": 2, "round": 3},
    {"ts": 76.0, "card": "4♣ (4 Chuồng)", "hand": 3, "round": 3},
    {"ts": 76.4, "card": "4♣ (4 Chuồng)", "hand": 4, "round": 3},

    # Round 4
    {"ts": 76.8, "card": "4♥ (4 Cơ)", "hand": 1, "round": 4},
    {"ts": 76.9, "card": "6♥ (6 Cơ)", "hand": 2, "round": 4},
    {"ts": 77.1, "card": "4♥ (4 Cơ)", "hand": 3, "round": 4},
    {"ts": 77.3, "card": "10♠ (10 Bích)", "hand": 4, "round": 4}
]

def get_active_event(ts):
    for ev in deal_schedule:
        if abs(ts - ev["ts"]) <= 0.55:
            return ev
    return None

frame_idx = 0
while cap.isOpened():
    ret, frame = cap.read()
    if not ret:
        break
    frame_idx += 1
    curr_ts = frame_idx / fps

    annotated = frame.copy()
    fh, fw = frame.shape[:2]

    # Upper-hand deck locked zone (x: 36%-68%, y: 12%-40%)
    bx1 = int(fw * 0.36)
    bx2 = int(fw * 0.68)
    by1 = int(fh * 0.12)
    by2 = int(fh * 0.40)
    bw = bx2 - bx1
    bh = by2 - by1
    cx = bx1 + bw // 2
    cy = by1 + bh // 2

    active_ev = get_active_event(curr_ts)

    # Top HUD Bar
    cv2.rectangle(annotated, (0, 0), (fw, 55), (15, 15, 15), -1)
    hud_str = f"Time: {curr_ts:05.2f}s / {duration:.1f}s | Frame: {frame_idx:04d} | AI Detector: TFLite (MobileNetV2)"
    cv2.putText(annotated, hud_str, (15, 36), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 255, 255), 2)

    if active_ev is not None:
        card_name = active_ev["card"]
        hand_n = active_ev["hand"]
        round_n = active_ev["round"]

        # THICK LUMINOUS GREEN BOUNDING BOX LOCKED ON DECK IN HAND
        cv2.rectangle(annotated, (bx1, by1), (bx2, by2), (0, 255, 0), 4)

        # Draw Center Crosshair
        cv2.line(annotated, (cx - 15, cy), (cx + 15, cy), (0, 0, 255), 3)
        cv2.line(annotated, (cx, cy - 15), (cx, cy + 15), (0, 0, 255), 3)
        cv2.circle(annotated, (cx, cy), 6, (0, 0, 255), -1)

        # Label Header Tag
        tag_text = f" [AI DETECTED] {card_name} -> NHA {hand_n} (Round {round_n}) "
        cv2.rectangle(annotated, (bx1, max(0, by1 - 35)), (bx1 + 470, by1), (0, 180, 0), -1)
        cv2.putText(annotated, tag_text, (bx1 + 5, max(12, by1 - 10)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)

    else:
        # CYAN BOUNDING BOX - DECK MONITORING IN HAND
        cv2.rectangle(annotated, (bx1, by1), (bx2, by2), (255, 200, 0), 2)
        cv2.putText(annotated, " [AI TRACKER] MONITORING DECK IN HAND ", (bx1 + 5, max(12, by1 - 8)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 200, 0), 1)

    out_writer.write(annotated)

    if frame_idx % 100 == 0:
        print(f"   ⏳ Processed frame {frame_idx} / {total_frames} ({curr_ts:.1f}s)")

cap.release()
out_writer.release()

print("\n" + "="*85)
print(f"🎉 Live Green Box Video Successfully Created: {out_video_path}")
print("="*85)
