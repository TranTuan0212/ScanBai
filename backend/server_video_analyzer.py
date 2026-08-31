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
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    return cv2.Laplacian(gray, cv2.CV_64F).var()

def analyze_video_event_driven(video_path, total_hands=3):
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
    
    # ---------------------------------------------------------
    # STAGE 1: Ultra-Fast Motion Trigger (OpenCV HSV Mask Only)
    # Detects ONLY when a card appears on table (0.5s - 1.0s window)
    # ---------------------------------------------------------
    detected_time_windows = [] # Array of (start_frame, end_frame)
    frame_idx = 0
    in_trigger = False
    trigger_start_frame = 0
    
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        frame_idx += 1
        
        if need_rotation:
            frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
            
        height, width, _ = frame.shape
        scale = 320.0 / float(width) if width > 320 else 1.0
        proc_frame = cv2.resize(frame, (int(width * scale), int(height * scale)), interpolation=cv2.INTER_NEAREST)
        
        hsv = cv2.cvtColor(proc_frame, cv2.COLOR_BGR2HSV)
        white_mask = cv2.inRange(hsv, (0, 0, 85), (180, 85, 255))
        cnts, _ = cv2.findContours(white_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        
        has_card_contour = False
        frame_area = proc_frame.shape[0] * proc_frame.shape[1]
        for c in cnts:
            area = cv2.contourArea(c)
            if area >= frame_area * 0.005 and area <= frame_area * 0.40:
                _, _, bw, bh = cv2.boundingRect(c)
                if 0.35 <= (float(bw)/float(bh)) <= 2.50:
                    has_card_contour = True
                    break
                    
        if has_card_contour:
            if not in_trigger:
                in_trigger = True
                trigger_start_frame = frame_idx
        else:
            if in_trigger:
                in_trigger = False
                trigger_end_frame = frame_idx
                # Only keep windows where a card was present for >= 2 frames
                if (trigger_end_frame - trigger_start_frame) >= 2:
                    detected_time_windows.append((trigger_start_frame, trigger_end_frame))
                    
    if in_trigger:
        detected_time_windows.append((trigger_start_frame, frame_idx))

    # ---------------------------------------------------------
    # STAGE 2: Sharpness Keyframe Picker & AI Classifier
    # Selects ONLY the single SHARPEST frame per card window!
    # Runs AI Neural Network ONLY ONCE PER CARD!
    # ---------------------------------------------------------
    card_events = []
    
    with torch.inference_mode():
        for window_idx, (start_f, end_f) in enumerate(detected_time_windows):
            best_sharpness = -1.0
            best_frame_data = None
            best_box = None
            best_crop = None
            best_timestamp = 0.0
            
            # Scan frames in this trigger window to find the sharpest keyframe
            cap.set(cv2.CAP_PROP_POS_FRAMES, start_f - 1)
            for current_f in range(start_f, end_f + 1):
                ret, frame = cap.read()
                if not ret: break
                
                if need_rotation:
                    frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
                    
                height, width, _ = frame.shape
                hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
                white_mask = cv2.inRange(hsv, (0, 0, 85), (180, 85, 255))
                cnts, _ = cv2.findContours(white_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                
                frame_area = width * height
                for c in cnts:
                    area = cv2.contourArea(c)
                    if area >= frame_area * 0.005 and area <= frame_area * 0.40:
                        x, y, bw, bh = cv2.boundingRect(c)
                        if 0.35 <= (float(bw)/float(bh)) <= 2.50:
                            card_roi = frame[y:y+bh, x:x+bw]
                            sharpness = compute_sharpness(card_roi)
                            if sharpness > best_sharpness:
                                best_sharpness = sharpness
                                best_frame_data = frame
                                best_box = (x, y, bw, bh)
                                best_crop = card_roi
                                best_timestamp = current_f / fps
                                
            # Run AI Neural Network ONLY on the Sharpest Keyframe!
            if best_frame_data is not None and best_box is not None:
                x, y, bw, bh = best_box
                c_w = max(14, int(bw * 0.28))
                c_h = max(22, int(c_w / 0.60))
                
                crop_tl = best_frame_data[y:y+c_h, x:x+c_w]
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
                        
                        annotated_crop = best_crop.copy()
                        cv2.rectangle(annotated_crop, (0, 0), (annotated_crop.shape[1]-1, annotated_crop.shape[0]-1), (0, 255, 0), 3)
                        cv2.putText(annotated_crop, f"{card_name} ({conf*100:.0f}%)", (5, max(18, annotated_crop.shape[0] - 8)),
                                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
                        
                        _, crop_buffer = cv2.imencode('.jpg', annotated_crop)
                        crop_base64 = base64.b64encode(crop_buffer).decode('utf-8') if crop_buffer is not None else ""
                        
                        card_events.append({
                            'timestamp': float(best_timestamp),
                            'card_name': card_name,
                            'confidence': float(conf),
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
        analyze_video_event_driven(v_path, t_hands)
