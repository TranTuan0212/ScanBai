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

def analyze_video_multi_candidate(video_path, total_hands=3):
    if not os.path.exists(video_path):
        print(json.dumps({"error": "Video file not found"}))
        return

    model = load_trained_model()
    cap = cv2.VideoCapture(video_path)
    
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    
    transform = transforms.Compose([
        transforms.Resize((160, 96)),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])
    
    frame_idx = 0
    raw_detections = []
    
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        frame_idx += 1
        timestamp = frame_idx / fps
        
        # 1. White Card Paper Isolation via HSV + RGB Contrast
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        blur = cv2.GaussianBlur(gray, (5, 5), 0)
        
        # White paper mask: Low Saturation (S <= 85), Medium-High Brightness (V >= 85)
        white_mask = cv2.inRange(hsv, (0, 0, 85), (180, 85, 255))
        _, otsu_mask = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        card_mask = cv2.bitwise_or(white_mask, otsu_mask)
        
        contours, _ = cv2.findContours(card_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        frame_area = width * height
        
        # Process ALL valid card candidate contours in the frame
        for cnt in contours:
            area = cv2.contourArea(cnt)
            if area < frame_area * 0.003 or area > frame_area * 0.45:
                continue
                
            x, y, bw, bh = cv2.boundingRect(cnt)
            aspect_ratio = float(bw) / float(bh)
            
            # Card aspect ratio range (Vertical portrait or horizontal landscape)
            if 0.30 <= aspect_ratio <= 2.80:
                # Extract 3 Candidate Crops:
                # Crop 1: Top-Left Corner Index (0-30% W x 0-35% H)
                c_w = max(10, int(bw * 0.30))
                c_h = max(10, int(bh * 0.35))
                crop1 = frame[y:y+c_h, x:x+c_w]
                
                # Crop 2: Top-Right Corner Index (70-100% W x 0-35% H)
                tr_x = max(0, x + bw - c_w)
                crop2_raw = frame[y:y+c_h, tr_x:tr_x+c_w]
                crop2 = cv2.flip(crop2_raw, 1) if crop2_raw.size > 0 else None
                
                best_conf = 0.0
                best_label = None
                best_crop_img = None
                
                for crop in [crop1, crop2]:
                    if crop is not None and crop.shape[0] > 8 and crop.shape[1] > 8:
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
                    # Draw green bounding box & label on card crop
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
    
    # Precise Multi-Card Fast Deal Clustering (80ms min inter-card gap)
    card_events = []
    last_emitted_box = None
    last_emitted_time = -999.0
    
    for det in raw_detections:
        timestamp = det['timestamp']
        x, y, bw, bh = det['box']
        
        # 80ms minimum gap allows tracking fast deals without missing cards!
        if (timestamp - last_emitted_time) >= 0.08:
            should_emit = True
            if last_emitted_box is not None:
                lx, ly, lw, lh = last_emitted_box
                dx = abs((x + bw/2.0) - (lx + lw/2.0))
                dy = abs((y + bh/2.0) - (ly + lh/2.0))
                # Only suppress if exact same card box position within 50ms
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
        analyze_video_multi_candidate(v_path, t_hands)
