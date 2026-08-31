import sys
import os
import cv2
import json
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

def has_card_ink(crop_bgr):
    if crop_bgr is None or crop_bgr.size == 0: return False
    hsv = cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2HSV)
    red1 = cv2.inRange(hsv, (0, 45, 40), (15, 255, 255))
    red2 = cv2.inRange(hsv, (150, 45, 40), (180, 255, 255))
    red_mask = cv2.bitwise_or(red1, red2)
    black_mask = cv2.inRange(hsv, (0, 0, 0), (180, 140, 75))
    ink_mask = cv2.bitwise_or(red_mask, black_mask)
    ink_ratio = float(cv2.countNonZero(ink_mask)) / float(crop_bgr.shape[0] * crop_bgr.shape[1])
    return (0.008 <= ink_ratio <= 0.40)

def process_video_and_render():
    video_path = os.path.join(os.path.dirname(__file__), "..", "Image", "IMG_8395.MOV")
    if not os.path.exists(video_path):
        video_path = os.path.join(os.path.dirname(__file__), "..", "Image", "ios1.mp4")
        
    out_dir = os.path.join(os.path.dirname(__file__), "..", "Image", "validation_output")
    os.makedirs(out_dir, exist_ok=True)
    
    out_video_path = os.path.join(out_dir, "IMG_8395_annotated.mp4")
    
    print(f"Reading video: {video_path}")
    model = load_trained_model()
    cap = cv2.VideoCapture(video_path)
    
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    raw_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    raw_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    
    print(f"Video Resolution: {raw_w}x{raw_h}, Total Frames: {total_frames}")
    
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
    
    frame_w = raw_h if need_rotation else raw_w
    frame_h = raw_w if need_rotation else raw_h
    
    fourcc = cv2.VideoWriter_fourcc(*'mp4v')
    out_writer = cv2.VideoWriter(out_video_path, fourcc, fps, (frame_w, frame_h))
    
    frame_idx = 0
    all_raw_detections = []
    
    with torch.inference_mode():
        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break
            frame_idx += 1
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
                
            # Gray Otsu thresholding + Adaptive Thresholding for room lighting
            gray = cv2.cvtColor(proc_frame, cv2.COLOR_BGR2GRAY)
            blur = cv2.GaussianBlur(gray, (5, 5), 0)
            
            _, otsu = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
            thresh = cv2.adaptiveThreshold(blur, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 15, 3)
            
            card_mask = cv2.bitwise_or(otsu, thresh)
            cnts, _ = cv2.findContours(card_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            
            frame_area = proc_w * proc_h
            frame_detections = []
            
            for c in cnts:
                area = cv2.contourArea(c)
                if area >= frame_area * 0.003 and area <= frame_area * 0.35:
                    rect = cv2.minAreaRect(c)
                    (cx, cy), (w, h), angle = rect
                    if w > 0 and h > 0:
                        aspect = max(w, h) / min(w, h)
                        if 1.10 <= aspect <= 3.6:
                            cx_f, cy_f = cx / scale, cy / scale
                            w_f, h_f = w / scale, h / scale
                            
                            box_pts = cv2.boxPoints(((cx_f, cy_f), (w_f, h_f), angle))
                            dst_w, dst_h = int(w_f), int(h_f)
                            if dst_w > dst_h:
                                dst_w, dst_h = dst_h, dst_w
                                angle += 90.0
                                
                            if dst_w >= 15 and dst_h >= 25:
                                dst_pts = torch.tensor([[0, 0], [dst_w-1, 0], [dst_w-1, dst_h-1], [0, dst_h-1]], dtype=torch.float32).numpy()
                                M = cv2.getPerspectiveTransform(box_pts.astype('float32'), dst_pts)
                                warped_card = cv2.warpPerspective(frame, M, (dst_w, dst_h))
                                
                                if warped_card.size > 0 and has_card_ink(warped_card):
                                    c_w = max(14, int(dst_w * 0.35))
                                    c_h = max(22, int(c_w / 0.60))
                                    
                                    crop_tl = warped_card[0:min(dst_h, c_h), 0:min(dst_w, c_w)]
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
                                        
                                        if conf >= 0.40:
                                            card_name = f"{RANK_NAMES[r_idx]} {SUIT_NAMES[s_idx]}"
                                            bx, by, bw_b, bh_b = int(cx_f - w_f/2), int(cy_f - h_f/2), int(w_f), int(h_f)
                                            frame_detections.append({
                                                'timestamp': timestamp,
                                                'frame_idx': frame_idx,
                                                'card_name': card_name,
                                                'confidence': conf,
                                                'box': (bx, by, bw_b, bh_b),
                                                'warped_card': warped_card
                                            })
                                            
            annotated_frame = frame.copy()
            for det in frame_detections:
                bx, by, bw_b, bh_b = det['box']
                card_name = det['card_name']
                conf = det['confidence']
                
                cv2.rectangle(annotated_frame, (max(0, bx), max(0, by)), (min(width-1, bx+bw_b), min(height-1, by+bh_b)), (0, 255, 0), 4)
                cv2.rectangle(annotated_frame, (max(0, bx), max(0, by-30)), (max(0, bx+140), max(0, by)), (0, 255, 0), -1)
                cv2.putText(annotated_frame, f"{card_name} ({conf*100:.0f}%)", (max(0, bx+4), max(15, by-8)),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 0, 0), 2)
                            
                all_raw_detections.append(det)
                
            out_writer.write(annotated_frame)

    cap.release()
    out_writer.release()
    print(f"Annotated video saved to: {out_video_path}")
    
    # Deduplicate into Card Dealt Events
    dealt_cards = []
    last_emitted_box = None
    last_emitted_time = -999.0
    
    for det in all_raw_detections:
        t = det['timestamp']
        bx, by, bw_b, bh_b = det['box']
        
        if (t - last_emitted_time) >= 0.15:
            dealt_cards.append(det)
            last_emitted_box = (bx, by, bw_b, bh_b)
            last_emitted_time = t
            
    print(f"\n==========================================")
    print(f"TOTAL UNIQUE CARDS EXTRACTED: {len(dealt_cards)}")
    print(f"==========================================")
    
    for idx, card in enumerate(dealt_cards):
        img_file = os.path.join(out_dir, f"card_{idx+1:02d}_{card['card_name'].replace(' ', '_')}.jpg")
        cv2.imwrite(img_file, card['warped_card'])
        print(f"  [Card #{idx+1:02d}] @ {card['timestamp']:.2f}s -> {card['card_name']} ({card['confidence']*100:.1f}%) -> Saved: {os.path.basename(img_file)}")

if __name__ == "__main__":
    process_video_and_render()
