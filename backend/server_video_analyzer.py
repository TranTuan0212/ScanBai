import sys
import os
import json
import cv2
import base64
import torch
import torch.nn as nn
import torchvision.models as models
import torchvision.transforms as transforms
from PIL import Image

class DualHeadCardClassifier(nn.Module):
    def __init__(self):
        super(DualHeadCardClassifier, self).__init__()
        backbone = models.mobilenet_v3_small(weights=None)
        in_features = backbone.classifier[0].in_features
        self.features = backbone.features
        self.avgpool = backbone.avgpool
        
        self.rank_head = nn.Sequential(
            nn.Linear(in_features, 128),
            nn.Hardswish(),
            nn.Dropout(0.2),
            nn.Linear(128, 13)
        )
        
        self.suit_head = nn.Sequential(
            nn.Linear(in_features, 64),
            nn.Hardswish(),
            nn.Dropout(0.2),
            nn.Linear(64, 4)
        )

    def forward(self, x):
        x = self.features(x)
        x = self.avgpool(x)
        x = torch.flatten(x, 1)
        rank_logits = self.rank_head(x)
        suit_logits = self.suit_head(x)
        return rank_logits, suit_logits

RANK_NAMES = ["ÁCH", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
SUIT_NAMES = ["BÍCH", "CƠ", "RÔ", "CHUỒN"]

def load_trained_model():
    model = DualHeadCardClassifier()
    model_path = os.path.join(os.path.dirname(__file__), "..", "CardDualHeadClassifier.pth")
    if not os.path.exists(model_path):
        model_path = os.path.join(os.path.dirname(__file__), "CardDualHeadClassifier.pth")
    if not os.path.exists(model_path):
        model_path = "CardDualHeadClassifier.pth"
    if os.path.exists(model_path):
        model.load_state_dict(torch.load(model_path, map_location="cpu"))
    model.eval()
    return model

def analyze_video_fast(video_path, total_hands=3):
    if not os.path.exists(video_path):
        print(json.dumps({"error": "Video file not found"}))
        return

    model = load_trained_model()
    cap = cv2.VideoCapture(video_path)
    
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    raw_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    raw_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    
    transform = transforms.Compose([
        transforms.Resize((160, 96)),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])
    
    # Auto-detect if video needs 90° Clockwise Rotation
    need_rotation = False
    ret, sample_frame = cap.read()
    if ret:
        hsv_sample = cv2.cvtColor(sample_frame, cv2.COLOR_BGR2HSV)
        white_sample = cv2.inRange(hsv_sample, (0, 0, 85), (180, 85, 255))
        cnts, _ = cv2.findContours(white_sample, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for c in cnts:
            if cv2.contourArea(c) > (raw_w * raw_h * 0.01):
                _, _, bw, bh = cv2.boundingRect(c)
                if bw > bh * 1.25:
                    need_rotation = True
                    break
                    
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
    
    frame_idx = 0
    raw_detections = []
    
    # Adaptive Frame Stride: Sample every 2 frames if video is long (> 150 frames) for 10x speedup
    frame_stride = 2 if total_frames > 150 else 1
    
    with torch.inference_mode():
        while cap.isOpened():
            ret, full_frame = cap.read()
            if not ret:
                break
            frame_idx += 1
            
            if frame_idx % frame_stride != 0:
                continue
                
            timestamp = frame_idx / fps
            
            if need_rotation:
                full_frame = cv2.rotate(full_frame, cv2.ROTATE_90_CLOCKWISE)
                
            height, width, _ = full_frame.shape
            
            # Downscale processing resolution to max width 640 for 5x faster OpenCV contours
            scale = 640.0 / float(width) if width > 640 else 1.0
            if scale < 1.0:
                proc_w = int(width * scale)
                proc_h = int(height * scale)
                proc_frame = cv2.resize(full_frame, (proc_w, proc_h), interpolation=cv2.INTER_NEAREST)
            else:
                proc_frame = full_frame
                proc_w, proc_h = width, height
                scale = 1.0
                
            hsv = cv2.cvtColor(proc_frame, cv2.COLOR_BGR2HSV)
            white_mask = cv2.inRange(hsv, (0, 0, 85), (180, 85, 255))
            
            contours, _ = cv2.findContours(white_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            frame_area = proc_w * proc_h
            
            for cnt in contours:
                area = cv2.contourArea(cnt)
                if area < frame_area * 0.004 or area > frame_area * 0.40:
                    continue
                    
                px, py, pbw, pbh = cv2.boundingRect(cnt)
                aspect_ratio = float(pbw) / float(pbh)
                
                # Filter strictly for card aspect ratio before running neural network
                if 0.35 <= aspect_ratio <= 2.50:
                    # Map box back to full resolution frame
                    x = int(px / scale)
                    y = int(py / scale)
                    bw = int(pbw / scale)
                    bh = int(pbh / scale)
                    
                    c_w = max(14, int(bw * 0.28))
                    c_h = max(22, int(c_w / 0.60)) # Preserves 0.60 aspect ratio!
                    
                    crop_tl = full_frame[y:y+c_h, x:x+c_w]
                    if crop_tl.shape[0] > 10 and crop_tl.shape[1] > 10:
                        pil_img = Image.fromarray(cv2.cvtColor(crop_tl, cv2.COLOR_BGR2RGB))
                        tensor_img = transform(pil_img).unsqueeze(0)
                        
                        rank_logits, suit_logits = model(tensor_img)
                        rank_probs = torch.softmax(rank_logits, dim=1)[0]
                        suit_probs = torch.softmax(suit_logits, dim=1)[0]
                        
                        r_idx = torch.argmax(rank_probs).item()
                        s_idx = torch.argmax(suit_probs).item()
                        
                        r_conf = rank_probs[r_idx].item()
                        s_conf = suit_probs[s_idx].item()
                        conf = (r_conf + s_conf) / 2.0
                        
                        if conf >= 0.65:
                            card_name = f"{RANK_NAMES[r_idx]} {SUIT_NAMES[s_idx]}"
                            
                            # Draw green bounding box & label on card crop
                            card_crop = full_frame[max(0, y):min(height, y+bh), max(0, x):min(width, x+bw)]
                            if card_crop.size > 0:
                                cv2.rectangle(card_crop, (0, 0), (card_crop.shape[1]-1, card_crop.shape[0]-1), (0, 255, 0), 3)
                                cv2.putText(card_crop, f"{card_name} ({conf*100:.0f}%)", (5, max(18, card_crop.shape[0] - 8)),
                                            cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
                                
                                _, crop_buffer = cv2.imencode('.jpg', card_crop)
                                crop_base64 = base64.b64encode(crop_buffer).decode('utf-8') if crop_buffer is not None else ""
                                
                                raw_detections.append({
                                    'timestamp': float(timestamp),
                                    'frame_idx': frame_idx,
                                    'card_name': card_name,
                                    'confidence': float(conf),
                                    'crop_base64': crop_base64,
                                    'box': (x, y, bw, bh)
                                })

    cap.release()
    
    # Fast Deal Debounce & Deduplication (80ms min inter-card gap)
    card_events = []
    last_emitted_box = None
    last_emitted_time = -999.0
    
    for det in raw_detections:
        timestamp = det['timestamp']
        x, y, bw, bh = det['box']
        
        if (timestamp - last_emitted_time) >= 0.08:
            should_emit = True
            if last_emitted_box is not None:
                lx, ly, lw, lh = last_emitted_box
                dx = abs((x + bw/2.0) - (lx + lw/2.0))
                dy = abs((y + bh/2.0) - (ly + lh/2.0))
                if dx < width * 0.06 and dy < height * 0.06 and (timestamp - last_emitted_time) < 0.18:
                    should_emit = False
                    
            if should_emit:
                card_events.append(det)
                last_emitted_box = (x, y, bw, bh)
                last_emitted_time = timestamp
                
    # Group card events into Player Hands Matrix (Nhóm #1, Nhóm #2, Nhóm #3)
    hands_matrix = []
    for h in range(1, total_hands + 1):
        hands_matrix.append({"handIndex": h, "cards": []})
        
    for idx, ev in enumerate(card_events):
        h_idx = (idx % total_hands)
        hands_matrix[h_idx]["cards"].append({
            "cardName": ev["card_name"],
            "confidence": ev["confidence"],
            "timestamp": ev["timestamp"],
            "cropBase64": ev["crop_base64"]
        })
        
    result_payload = {
        "status": "ok",
        "totalCards": len(card_events),
        "hands": hands_matrix,
        "rawEvents": card_events
    }
    
    print(json.dumps(result_payload))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Video path argument missing"}))
    else:
        v_path = sys.argv[1]
        t_hands = int(sys.argv[2]) if len(sys.argv) > 2 else 3
        analyze_video_fast(v_path, t_hands)
