import sys
import os
import json
import cv2
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

def compute_laplacian_sharpness(img_bgr):
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    return cv2.Laplacian(gray, cv2.CV_64F).var()

def analyze_video(video_path, total_hands=3):
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
        
        # Adaptive Color Segmentation for White Card Paper & Card Borders
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        blur = cv2.GaussianBlur(gray, (5, 5), 0)
        
        # Multi-threshold: Adaptive + Otsu to capture cards under any lighting condition
        thresh1 = cv2.adaptiveThreshold(blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 11, 2)
        _, thresh2 = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        combined_thresh = cv2.bitwise_or(thresh1, thresh2)
        
        contours, _ = cv2.findContours(combined_thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        frame_area = width * height
        
        for cnt in contours:
            area = cv2.contourArea(cnt)
            if area < frame_area * 0.003 or area > frame_area * 0.45:
                continue
                
            x, y, bw, bh = cv2.boundingRect(cnt)
            aspect_ratio = float(bw) / float(bh)
            if 0.30 <= aspect_ratio <= 2.80:
                # 1. Evaluate Top-Left Corner Crop
                corner_w = max(12, int(bw * 0.32))
                corner_h = max(12, int(bh * 0.35))
                corner1 = frame[y:y+corner_h, x:x+corner_w]
                
                # 2. Evaluate Bottom-Right Corner Crop (Rotated 180°)
                br_x = max(0, x + bw - corner_w)
                br_y = max(0, y + bh - corner_h)
                corner2_raw = frame[br_y:br_y+corner_h, br_x:br_x+corner_w]
                corner2 = cv2.rotate(corner2_raw, cv2.ROTATE_180) if corner2_raw.size > 0 else None
                
                best_conf = 0.0
                best_label = None
                
                for crop in [corner1, corner2]:
                    if crop is not None and crop.shape[0] > 10 and crop.shape[1] > 10:
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
                                
                if best_conf >= 0.55 and best_label is not None:
                    sharpness = compute_laplacian_sharpness(frame[y:y+bh, x:x+bw])
                    raw_detections.append({
                        'timestamp': float(timestamp),
                        'frame_idx': frame_idx,
                        'card_name': best_label,
                        'confidence': float(best_conf),
                        'sharpness': float(sharpness),
                        'box': (x, y, bw, bh)
                    })

    cap.release()
    
    # Temporal Clustering & CapCut-Style Keyframe Selection
    # Group raw detections by temporal gap (> 0.22s) and spatial centroid
    card_events = []
    current_cluster = []
    
    for det in raw_detections:
        if not current_cluster:
            current_cluster.append(det)
        else:
            last_det = current_cluster[-1]
            time_gap = det['timestamp'] - last_det['timestamp']
            
            if time_gap <= 0.22:
                current_cluster.append(det)
            else:
                # Select the highest quality keyframe in this temporal cluster (Best confidence * sharpness)
                best_frame = max(current_cluster, key=lambda d: d['confidence'] * 0.7 + (min(1.0, d['sharpness'] / 500.0) * 0.3))
                card_events.append(best_frame)
                current_cluster = [det]
                
    if current_cluster:
        best_frame = max(current_cluster, key=lambda d: d['confidence'] * 0.7 + (min(1.0, d['sharpness'] / 500.0) * 0.3))
        card_events.append(best_frame)
        
    # Group card events into Player Hands Matrix
    hands_matrix = []
    for h in range(1, total_hands + 1):
        hands_matrix.append({"handIndex": h, "cards": []})
        
    for idx, ev in enumerate(card_events):
        h_idx = (idx % total_hands)
        hands_matrix[h_idx]["cards"].append(ev["card_name"])
        
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
        analyze_video(v_path, t_hands)
