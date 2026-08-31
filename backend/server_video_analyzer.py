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

def has_playing_card_ink(crop_bgr):
    """
    Verifies that candidate crop contains printed Rank/Suit INK (Red or Black) on White Paper.
    Rejects blank white walls, tiles, bedsheets, and white T-shirts!
    """
    if crop_bgr is None or crop_bgr.size == 0:
        return False
    hsv = cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2HSV)
    
    # Red ink mask (Hearts ♥ and Diamonds ♦)
    red1 = cv2.inRange(hsv, (0, 50, 40), (12, 255, 255))
    red2 = cv2.inRange(hsv, (155, 50, 40), (180, 255, 255))
    red_mask = cv2.bitwise_or(red1, red2)
    
    # Black ink mask (Spades ♠, Clubs ♣, and rank numbers)
    black_mask = cv2.inRange(hsv, (0, 0, 0), (180, 110, 60))
    
    ink_mask = cv2.bitwise_or(red_mask, black_mask)
    ink_ratio = float(cv2.countNonZero(ink_mask)) / float(crop_bgr.shape[0] * crop_bgr.shape[1])
    
    # Playing cards MUST have 1.2% to 30% printed ink inside paper
    return (0.012 <= ink_ratio <= 0.30)

def extract_held_cards_unwarp(full_frame, c, scale):
    rect = cv2.minAreaRect(c)
    (cx, cy), (w, h), angle = rect
    
    cx, cy = cx / scale, cy / scale
    w, h = w / scale, h / scale
    
    if w < 10 or h < 10:
        return None
        
    if w > h:
        w, h = h, w
        angle += 90.0
        
    aspect_ratio = float(h) / float(w)
    if not (1.1 <= aspect_ratio <= 3.5):
        return None
        
    box_pts = cv2.boxPoints(((cx, cy), (w, h), angle))
    dst_w, dst_h = int(w), int(h)
    
    if dst_w < 15 or dst_h < 25:
        return None
        
    dst_pts = torch.tensor([[0, 0], [dst_w-1, 0], [dst_w-1, dst_h-1], [0, dst_h-1]], dtype=torch.float32).numpy()
    M = cv2.getPerspectiveTransform(box_pts.astype('float32'), dst_pts)
    warped_card = cv2.warpPerspective(full_frame, M, (dst_w, dst_h))
    
    if warped_card.size == 0:
        return None
        
    # Verify candidate card contains Rank/Suit INK (filters out white walls and T-shirts!)
    if not has_playing_card_ink(warped_card):
        return None
        
    c_w = max(14, int(dst_w * 0.35))
    c_h = max(22, int(c_w / 0.60))
    
    crops = []
    # 1. Top-Left Corner
    crop_tl = warped_card[0:min(dst_h, c_h), 0:min(dst_w, c_w)]
    if crop_tl.shape[0] > 10 and crop_tl.shape[1] > 10:
        crops.append(crop_tl)
        
    # 2. Bottom-Right Corner (180° rotated)
    br_y = max(0, dst_h - c_h)
    br_x = max(0, dst_w - c_w)
    crop_br = warped_card[br_y:dst_h, br_x:dst_w]
    if crop_br.shape[0] > 10 and crop_br.shape[1] > 10:
        crops.append(cv2.rotate(crop_br, cv2.ROTATE_180))
        
    return crops, warped_card, (int(cx - w/2), int(cy - h/2), int(w), int(h))

def analyze_video_multi_threshold(video_path, total_hands=3):
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
            white_mask = cv2.inRange(hsv, (0, 0, 70), (180, 95, 255))
            
            gray = cv2.cvtColor(proc_frame, cv2.COLOR_BGR2GRAY)
            blur = cv2.GaussianBlur(gray, (5, 5), 0)
            thresh = cv2.adaptiveThreshold(blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 11, 2)
            
            card_mask = cv2.bitwise_or(white_mask, thresh)
            cnts, _ = cv2.findContours(card_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            
            frame_area = proc_w * proc_h
            best_contour = None
            best_area = 0
            
            for c in cnts:
                area = cv2.contourArea(c)
                if area >= frame_area * 0.003 and area <= frame_area * 0.35:
                    rect = cv2.minAreaRect(c)
                    (cx, cy), (w, h), angle = rect
                    if w > 0 and h > 0:
                        aspect = max(w, h) / min(w, h)
                        if 1.1 <= aspect <= 3.5:
                            if area > best_area:
                                best_area = area
                                best_contour = c
                                
            if best_contour is not None:
                res = extract_held_cards_unwarp(frame, best_contour, scale)
                if res:
                    crops, warped_card, (x, y, bw, bh) = res
                    sharpness = compute_sharpness(warped_card)
                    
                    current_track.append({
                        'timestamp': timestamp,
                        'frame': frame,
                        'box': (x, y, bw, bh),
                        'normBox': (max(0, x) / width, max(0, y) / height, min(width, bw) / width, min(height, bh) / height),
                        'sharpness': sharpness,
                        'crops': crops,
                        'warped_card': warped_card
                    })
            else:
                if len(current_track) >= 2:
                    best_item = max(current_track, key=lambda d: d['sharpness'])
                    best_conf = 0.0
                    best_label = None
                    
                    for crop in best_item['crops']:
                        pil_img = Image.fromarray(cv2.cvtColor(crop, cv2.COLOR_BGR2RGB))
                        tensor_img = transform(pil_img).unsqueeze(0)
                        
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
                            
                    if best_conf >= 0.50 and best_label is not None:
                        annotated = best_item['warped_card'].copy()
                        cv2.rectangle(annotated, (0, 0), (annotated.shape[1]-1, annotated.shape[0]-1), (0, 255, 0), 3)
                        cv2.putText(annotated, f"{best_label} ({best_conf*100:.0f}%)", (5, max(18, annotated.shape[0] - 8)),
                                    cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
                        
                        _, crop_buffer = cv2.imencode('.jpg', annotated)
                        crop_base64 = base64.b64encode(crop_buffer).decode('utf-8') if crop_buffer is not None else ""
                        
                        card_events.append({
                            'timestamp': float(best_item['timestamp']),
                            'card_name': best_label,
                            'confidence': float(best_conf),
                            'normBox': best_item['normBox'],
                            'crop_base64': crop_base64
                        })
                    current_track = []
                else:
                    current_track = []

        if len(current_track) >= 2:
            best_item = max(current_track, key=lambda d: d['sharpness'])
            best_conf = 0.0
            best_label = None
            
            for crop in best_item['crops']:
                pil_img = Image.fromarray(cv2.cvtColor(crop, cv2.COLOR_BGR2RGB))
                tensor_img = transform(pil_img).unsqueeze(0)
                
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
                    
            if best_conf >= 0.50 and best_label is not None:
                annotated = best_item['warped_card'].copy()
                cv2.rectangle(annotated, (0, 0), (annotated.shape[1]-1, annotated.shape[0]-1), (0, 255, 0), 3)
                cv2.putText(annotated, f"{best_label} ({best_conf*100:.0f}%)", (5, max(18, annotated.shape[0] - 8)),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
                
                _, crop_buffer = cv2.imencode('.jpg', annotated)
                crop_base64 = base64.b64encode(crop_buffer).decode('utf-8') if crop_buffer is not None else ""
                
                card_events.append({
                    'timestamp': float(best_item['timestamp']),
                    'card_name': best_label,
                    'confidence': float(best_conf),
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
        analyze_video_multi_threshold(v_path, t_hands)
