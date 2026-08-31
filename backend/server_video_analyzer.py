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

def compute_sharpness(img_bgr):
    if img_bgr is None or img_bgr.size == 0: return 0.0
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    return cv2.Laplacian(gray, cv2.CV_64F).var()

def is_valid_card_contour(c, proc_w, proc_h):
    area = cv2.contourArea(c)
    frame_area = proc_w * proc_h
    # Card area must be between 0.4% and 25% of frame
    if area < frame_area * 0.004 or area > frame_area * 0.25:
        return False, None
        
    px, py, pbw, pbh = cv2.boundingRect(c)
    aspect_ratio = float(pbw) / float(pbh)
    
    # Standard card ratio range
    if not (0.35 <= aspect_ratio <= 2.20):
        return False, None
        
    # Polygon approximation: Cards are 4-sided quadrilaterals!
    peri = cv2.arcLength(c, True)
    approx = cv2.approxPolyDP(c, 0.035 * peri, True)
    
    # Shirt sleeves and arms have curved borders with > 6 vertices
    if len(approx) > 8:
        return False, None
        
    return True, (px, py, pbw, pbh)

def analyze_video_with_video_overlay(video_path, total_hands=3):
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
    stride = 2 if total_frames > 120 else 1
    
    current_track = []
    card_events = []
    
    with torch.inference_mode():
        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break
            frame_idx += 1
            
            if frame_idx % stride != 0:
                continue
                
            timestamp = frame_idx / fps
            
            if need_rotation:
                frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
                
            height, width, _ = frame.shape
            scale = 480.0 / float(width) if width > 480 else 1.0
            
            if scale < 1.0:
                proc_w = int(width * scale)
                proc_h = int(height * scale)
                proc_frame = cv2.resize(frame, (proc_w, proc_h), interpolation=cv2.INTER_NEAREST)
            else:
                proc_frame = frame
                proc_w, proc_h = width, height
                scale = 1.0
                
            hsv = cv2.cvtColor(proc_frame, cv2.COLOR_BGR2HSV)
            white_mask = cv2.inRange(hsv, (0, 0, 85), (180, 85, 255))
            cnts, _ = cv2.findContours(white_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            
            best_contour_box = None
            best_area = 0
            
            for c in cnts:
                is_valid, box = is_valid_card_contour(c, proc_w, proc_h)
                if is_valid and box is not None:
                    area = box[2] * box[3]
                    if area > best_area:
                        best_area = area
                        best_contour_box = box
                            
            if best_contour_box is not None:
                px, py, pbw, pbh = best_contour_box
                x = int(px / scale)
                y = int(py / scale)
                bw = int(pbw / scale)
                bh = int(pbh / scale)
                
                card_roi = frame[max(0, y):min(height, y+bh), max(0, x):min(width, x+bw)]
                sharpness = compute_sharpness(card_roi)
                
                current_track.append({
                    'timestamp': timestamp,
                    'frame': frame,
                    'box': (x, y, bw, bh),
                    'normBox': (x / width, y / height, bw / width, bh / height),
                    'sharpness': sharpness,
                    'card_roi': card_roi
                })
            else:
                if len(current_track) >= 2:
                    best_item = max(current_track, key=lambda d: d['sharpness'])
                    f = best_item['frame']
                    x, y, bw, bh = best_item['box']
                    c_w = max(14, int(bw * 0.28))
                    c_h = max(22, int(c_w / 0.60))
                    
                    crop_tl = f[y:y+c_h, x:x+c_w]
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
                        
                        if conf >= 0.55:
                            card_name = f"{RANK_NAMES[r_idx]} {SUIT_NAMES[s_idx]}"
                            annotated = best_item['card_roi'].copy()
                            cv2.rectangle(annotated, (0, 0), (annotated.shape[1]-1, annotated.shape[0]-1), (0, 255, 0), 3)
                            cv2.putText(annotated, f"{card_name} ({conf*100:.0f}%)", (5, max(18, annotated.shape[0] - 8)),
                                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
                            
                            _, crop_buffer = cv2.imencode('.jpg', annotated)
                            crop_base64 = base64.b64encode(crop_buffer).decode('utf-8') if crop_buffer is not None else ""
                            
                            card_events.append({
                                'timestamp': float(best_item['timestamp']),
                                'card_name': card_name,
                                'confidence': float(conf),
                                'normBox': best_item['normBox'],
                                'crop_base64': crop_base64
                            })
                    current_track = []
                else:
                    current_track = []

        if len(current_track) >= 2:
            best_item = max(current_track, key=lambda d: d['sharpness'])
            f = best_item['frame']
            x, y, bw, bh = best_item['box']
            c_w = max(14, int(bw * 0.28))
            c_h = max(22, int(c_w / 0.60))
            
            crop_tl = f[y:y+c_h, x:x+c_w]
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
                
                if conf >= 0.55:
                    card_name = f"{RANK_NAMES[r_idx]} {SUIT_NAMES[s_idx]}"
                    annotated = best_item['card_roi'].copy()
                    cv2.rectangle(annotated, (0, 0), (annotated.shape[1]-1, annotated.shape[0]-1), (0, 255, 0), 3)
                    cv2.putText(annotated, f"{card_name} ({conf*100:.0f}%)", (5, max(18, annotated.shape[0] - 8)),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
                    
                    _, crop_buffer = cv2.imencode('.jpg', annotated)
                    crop_base64 = base64.b64encode(crop_buffer).decode('utf-8') if crop_buffer is not None else ""
                    
                    card_events.append({
                        'timestamp': float(best_item['timestamp']),
                        'card_name': card_name,
                        'confidence': float(conf),
                        'normBox': best_item['normBox'],
                        'crop_base64': crop_base64
                    })

    cap.release()
    
    # Group card events into Player Hands Matrix
    hands_matrix = []
    for h in range(1, total_hands + 1):
        hands_matrix.append({"handIndex": h, "cards": []})
        
    for idx, ev in enumerate(card_events):
        h_idx = (idx % total_hands)
        hands_matrix[h_idx]["cards"].append({
            "cardName": ev["card_name"],
            "confidence": ev["confidence"],
            "timestamp": ev["timestamp"],
            "normBox": ev["normBox"],
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
        analyze_video_with_video_overlay(v_path, t_hands)
