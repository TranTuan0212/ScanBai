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

def analyze_video_robust(video_path, total_hands=3):
    if not os.path.exists(video_path):
        print(json.dumps({"error": "Video file not found"}))
        return

    model = load_trained_model()
    cap = cv2.VideoCapture(video_path)
    
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    raw_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    raw_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    
    transform = transforms.Compose([
        transforms.Resize((160, 96)),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])
    
    # 1. Determine if video needs 90° Clockwise Rotation (Portrait videos saved in landscape stream)
    need_rotation = False
    ret, sample_frame = cap.read()
    if ret:
        # Check if sample frame is sideways (e.g. 720x1280 but actually portrait)
        hsv_sample = cv2.cvtColor(sample_frame, cv2.COLOR_BGR2HSV)
        white_sample = cv2.inRange(hsv_sample, (0, 0, 85), (180, 85, 255))
        cnts, _ = cv2.findContours(white_sample, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for c in cnts:
            if cv2.contourArea(c) > (raw_w * raw_h * 0.01):
                _, _, bw, bh = cv2.boundingRect(c)
                # If cards appear horizontal (bw > bh * 1.3), the video is turned 90° sideways!
                if bw > bh * 1.3:
                    need_rotation = True
                    break
                    
    # Reset video capture to start
    cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
    
    frame_idx = 0
    raw_detections = []
    
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        frame_idx += 1
        timestamp = frame_idx / fps
        
        # Apply 90° rotation if video was recorded vertically on phone
        if need_rotation:
            frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
            
        height, width, _ = frame.shape
        
        # Color segmentation for card paper
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        blur = cv2.GaussianBlur(gray, (5, 5), 0)
        
        white_mask = cv2.inRange(hsv, (0, 0, 80), (180, 90, 255))
        _, otsu_mask = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        card_mask = cv2.bitwise_or(white_mask, otsu_mask)
        
        contours, _ = cv2.findContours(card_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        frame_area = width * height
        
        for cnt in contours:
            area = cv2.contourArea(cnt)
            if area < frame_area * 0.003 or area > frame_area * 0.45:
                continue
                
            x, y, bw, bh = cv2.boundingRect(cnt)
            aspect_ratio = float(bw) / float(bh)
            
            if 0.30 <= aspect_ratio <= 2.80:
                c_w = max(10, int(bw * 0.32))
                c_h = max(10, int(bh * 0.35))
                
                # Extract 4 corner crops to handle ANY card orientation/angle!
                crops = []
                
                # 1. Top-Left Corner
                crop_tl = frame[y:y+c_h, x:x+c_w]
                if crop_tl.size > 0: crops.append(crop_tl)
                
                # 2. Bottom-Right Corner (Rotated 180°)
                br_x = max(0, x + bw - c_w)
                br_y = max(0, y + bh - c_h)
                crop_br_raw = frame[br_y:br_y+c_h, br_x:br_x+c_w]
                if crop_br_raw.size > 0: crops.append(cv2.rotate(crop_br_raw, cv2.ROTATE_180))
                
                # 3. Top-Right Corner (Flipped)
                tr_x = max(0, x + bw - c_w)
                crop_tr_raw = frame[y:y+c_h, tr_x:tr_x+c_w]
                if crop_tr_raw.size > 0: crops.append(cv2.flip(crop_tr_raw, 1))
                
                best_conf = 0.0
                best_label = None
                best_crop_img = None
                
                for crop in crops:
                    if crop.shape[0] > 8 and crop.shape[1] > 8:
                        pil_img = Image.fromarray(cv2.cvtColor(crop, cv2.COLOR_BGR2RGB))
                        tensor_img = transform(pil_img).unsqueeze(0)
                        
                        with torch.no_grad():
                            rank_logits, suit_logits = model(tensor_img)
                            rank_probs = torch.softmax(rank_logits, dim=1)[0]
                            suit_probs = torch.softmax(suit_logits, dim=1)[0]
                            
                            r_idx = torch.argmax(rank_probs).item()
                            s_idx = torch.argmax(suit_probs).item()
                            
                            r_conf = rank_probs[r_idx].item()
                            s_conf = suit_probs[s_idx].item()
                            conf = (r_conf + s_conf) / 2.0
                            
                            if conf > best_conf:
                                best_conf = conf
                                best_label = f"{RANK_NAMES[r_idx]} {SUIT_NAMES[s_idx]}"
                                best_crop_img = crop
                                
                if best_conf >= 0.55 and best_label is not None:
                    card_crop = frame[max(0, y):min(height, y+bh), max(0, x):min(width, x+bw)]
                    cv2.rectangle(card_crop, (0, 0), (card_crop.shape[1]-1, card_crop.shape[0]-1), (0, 255, 0), 3)
                    cv2.putText(card_crop, best_label, (5, max(18, card_crop.shape[0] - 8)),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
                    
                    _, crop_buffer = cv2.imencode('.jpg', card_crop)
                    crop_base64 = base64.b64encode(crop_buffer).decode('utf-8') if crop_buffer is not None else ""
                    
                    raw_detections.append({
                        'timestamp': float(timestamp),
                        'frame_idx': frame_idx,
                        'card_name': best_label,
                        'confidence': float(best_conf),
                        'crop_base64': crop_base64,
                        'box': (x, y, bw, bh)
                    })

    cap.release()
    
    # Fast Deal Debounce & Deduplication
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
        analyze_video_robust(v_path, t_hands)
