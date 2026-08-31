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
        model_path = "CardDualHeadClassifier.pth"
    if os.path.exists(model_path):
        model.load_state_dict(torch.load(model_path, map_location="cpu"))
    model.eval()
    return model

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
    
    detected_cards = []
    frame_idx = 0
    last_emitted_box = None
    last_emitted_time = -999.0
    
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        frame_idx += 1
        timestamp = frame_idx / fps
        
        # Sample every 2 frames for ultra-fast processing (< 5 seconds for full 10s video)
        if frame_idx % 2 != 0:
            continue
            
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        blur = cv2.GaussianBlur(gray, (5, 5), 0)
        _, thresh = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        
        contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        frame_area = width * height
        
        best_candidate_box = None
        best_candidate_area = 0
        
        for cnt in contours:
            area = cv2.contourArea(cnt)
            if area < frame_area * 0.004 or area > frame_area * 0.40:
                continue
                
            x, y, bw, bh = cv2.boundingRect(cnt)
            aspect_ratio = float(bw) / float(bh)
            if 0.35 <= aspect_ratio <= 2.50:
                if area > best_candidate_area:
                    best_candidate_area = area
                    best_candidate_box = (x, y, bw, bh)
                    
        if best_candidate_box is not None:
            x, y, bw, bh = best_candidate_box
            corner_w = max(10, int(bw * 0.28))
            corner_h = max(10, int(bh * 0.32))
            corner_bgr = frame[y:y+corner_h, x:x+corner_w]
            
            if corner_bgr.shape[0] > 10 and corner_bgr.shape[1] > 10:
                pil_img = Image.fromarray(cv2.cvtColor(corner_bgr, cv2.COLOR_BGR2RGB))
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
                    
                    r_name = RANK_NAMES[r_idx]
                    s_name = SUIT_NAMES[s_idx]
                    card_name = f"{r_name} {s_name}"
                    
                if conf >= 0.65 and (timestamp - last_emitted_time) > 0.15:
                    should_emit = True
                    if last_emitted_box is not None:
                        lx, ly, lw, lh = last_emitted_box
                        dx = abs((x + bw/2.0) - (lx + lw/2.0))
                        dy = abs((y + bh/2.0) - (ly + lh/2.0))
                        if dx < width * 0.08 and dy < height * 0.08:
                            should_emit = False
                            
                    if should_emit:
                        detected_cards.append({
                            'card_name': card_name,
                            'confidence': float(conf),
                            'timestamp': float(timestamp)
                        })
                        last_emitted_box = (x, y, bw, bh)
                        last_emitted_time = timestamp

    cap.release()
    
    # Group detected cards by Player Hands (Nhóm #1, Nhóm #2, Nhóm #3)
    hands_matrix = []
    for h in range(1, total_hands + 1):
        hands_matrix.append({"handIndex": h, "cards": []})
        
    for idx, card in enumerate(detected_cards):
        h_idx = (idx % total_hands)
        hands_matrix[h_idx]["cards"].append(card["card_name"])
        
    result_payload = {
        "status": "ok",
        "totalCards": len(detected_cards),
        "hands": hands_matrix,
        "rawEvents": detected_cards
    }
    
    print(json.dumps(result_payload))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Video path argument missing"}))
    else:
        v_path = sys.argv[1]
        t_hands = int(sys.argv[2]) if len(sys.argv) > 2 else 3
        analyze_video(v_path, t_hands)
