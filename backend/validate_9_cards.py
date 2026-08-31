import sys
import os
import cv2
import json
import base64
import numpy as np

# Add backend directory to sys.path
sys.path.append(os.path.dirname(__file__))
import server_video_analyzer

def run_validation():
    video_path = os.path.join(os.path.dirname(__file__), "..", "Image", "IMG_8395.MOV")
    if not os.path.exists(video_path):
        video_path = os.path.join(os.path.dirname(__file__), "..", "Image", "ios1.mp4")
        
    print(f"=== RUNNING VALIDATION ON VIDEO: {video_path} ===")
    
    # Run analysis
    model = server_video_analyzer.load_trained_model()
    cap = cv2.VideoCapture(video_path)
    
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    raw_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    raw_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    
    print(f"Video Info: {raw_w}x{raw_h} @ {fps:.1f} FPS, {total_frames} total frames")
    
    # We want to extract ALL candidate cards across the video
    # Let's inspect raw detections from server_video_analyzer
    output_dir = os.path.join(os.path.dirname(__file__), "..", "Image", "validation_output")
    os.makedirs(output_dir, exist_ok=True)
    
    # Run the main analyzer function directly
    server_video_analyzer.analyze_video_multi_threshold(video_path, 3)

if __name__ == "__main__":
    run_validation()
