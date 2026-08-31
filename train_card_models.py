import os
import sys
import glob
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader
import torchvision.models as models
import torchvision.transforms as transforms
from PIL import Image
import coremltools as ct

# Map Folder names in dataset/cards to Rank (0..12) and Suit (0..3)
RANK_MAP = {
    "ace": 0, "two": 1, "three": 2, "four": 3, "five": 4, "six": 5,
    "seven": 6, "eight": 7, "nine": 8, "ten": 9, "jack": 10, "queen": 11, "king": 12
}

SUIT_MAP = {
    "spades": 0,   # ♠ Bích
    "hearts": 1,   # ♥ Cơ
    "diamonds": 2, # ♦ Rô
    "clubs": 3     # ♣ Chuồn
}

def parse_card_dataset(base_dir, max_per_class=50):
    samples = []
    print(f"[INFO] Parsing dataset images in: {base_dir}", flush=True)
    folder_names = os.listdir(base_dir)
    for folder in folder_names:
        folder_path = os.path.join(base_dir, folder)
        if not os.path.isdir(folder_path):
            continue
        
        parts = folder.lower().strip().split(" of ")
        if len(parts) != 2:
            continue
        
        rank_str, suit_str = parts[0].strip(), parts[1].strip()
        if rank_str not in RANK_MAP or suit_str not in SUIT_MAP:
            continue
        
        rank_idx = RANK_MAP[rank_str]
        suit_idx = SUIT_MAP[suit_str]
        
        class_count = 0
        for img_ext in ["*.jpg", "*.jpeg", "*.png"]:
            for img_path in glob.glob(os.path.join(folder_path, img_ext)):
                samples.append((img_path, rank_idx, suit_idx))
                class_count += 1
                if max_per_class and class_count >= max_per_class:
                    break
            if max_per_class and class_count >= max_per_class:
                break
                
    print(f"[OK] Found {len(samples)} valid samples for {len(RANK_MAP)} Ranks and {len(SUIT_MAP)} Suits!", flush=True)
    return samples

class CornerCropDataset(Dataset):
    def __init__(self, samples, transform=None):
        self.transform = transform
        self.data = []
        print(f"[INFO] Pre-loading and cropping {len(samples)} images into RAM for fast execution...", flush=True)
        for idx, (img_path, rank_label, suit_label) in enumerate(samples):
            try:
                image = Image.open(img_path).convert('RGB')
                w, h = image.size
                corner_w = max(10, int(w * 0.28))
                corner_h = max(10, int(h * 0.32))
                corner_crop = image.crop((0, 0, corner_w, corner_h))
                
                if self.transform:
                    corner_crop = self.transform(corner_crop)
                    
                self.data.append((corner_crop, rank_label, suit_label))
            except Exception:
                pass
        print(f"[OK] Successfully pre-loaded {len(self.data)} cropped samples into RAM!", flush=True)

    def __len__(self):
        return len(self.data)

    def __getitem__(self, idx):
        crop_tensor, rank_label, suit_label = self.data[idx]
        return crop_tensor, torch.tensor(rank_label, dtype=torch.long), torch.tensor(suit_label, dtype=torch.long)

class DualHeadCardClassifier(nn.Module):
    def __init__(self):
        super(DualHeadCardClassifier, self).__init__()
        backbone = models.mobilenet_v3_small(weights=models.MobileNet_V3_Small_Weights.DEFAULT)
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

def train_and_export():
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"[INFO] Running Advanced PyTorch Training on Device: {device}", flush=True)
    
    train_dir = os.path.join("dataset", "cards", "train")
    val_dir = os.path.join("dataset", "cards", "valid")
    
    train_samples = parse_card_dataset(train_dir, max_per_class=60)
    val_samples = parse_card_dataset(val_dir, max_per_class=15)
    
    if len(train_samples) == 0:
        print("[ERROR] No training samples found!", flush=True)
        return

    # Advanced Production Augmentations: Finger Occlusion (RandomErasing), Yellow Lighting (ColorJitter), Camera Tilt (Affine/Perspective)
    train_transform = transforms.Compose([
        transforms.Resize((160, 96)),
        transforms.ColorJitter(brightness=0.35, contrast=0.35, hue=0.10),
        transforms.RandomAffine(degrees=12, translate=(0.05, 0.05), scale=(0.90, 1.10), shear=8),
        transforms.RandomPerspective(distortion_scale=0.20, p=0.40),
        transforms.ToTensor(),
        transforms.RandomErasing(p=0.45, scale=(0.02, 0.20), ratio=(0.3, 3.3), value=0),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])
    
    val_transform = transforms.Compose([
        transforms.Resize((160, 96)),
        transforms.ToTensor(),
        transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
    ])

    train_dataset = CornerCropDataset(train_samples, transform=train_transform)
    val_dataset = CornerCropDataset(val_samples, transform=val_transform)
    
    train_loader = DataLoader(train_dataset, batch_size=64, shuffle=True, num_workers=0)
    val_loader = DataLoader(val_dataset, batch_size=64, shuffle=False, num_workers=0)

    model = DualHeadCardClassifier().to(device)
    criterion_rank = nn.CrossEntropyLoss()
    criterion_suit = nn.CrossEntropyLoss()
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)

    epochs = 15
    best_val_loss = float('inf')

    print(f"[START] Starting Production Training with Advanced Augmentations for {epochs} Epochs...", flush=True)
    for epoch in range(epochs):
        model.train()
        running_loss = 0.0
        for images, rank_targets, suit_targets in train_loader:
            images = images.to(device)
            rank_targets = rank_targets.to(device)
            suit_targets = suit_targets.to(device)

            optimizer.zero_grad()
            rank_preds, suit_preds = model(images)
            
            loss_rank = criterion_rank(rank_preds, rank_targets)
            loss_suit = criterion_suit(suit_preds, suit_targets)
            total_loss = loss_rank + loss_suit
            
            total_loss.backward()
            optimizer.step()
            running_loss += total_loss.item() * images.size(0)

        epoch_train_loss = running_loss / max(1, len(train_dataset))

        # Validation Phase
        model.eval()
        val_loss = 0.0
        rank_correct = 0
        suit_correct = 0
        total_val = 0

        with torch.no_grad():
            for images, rank_targets, suit_targets in val_loader:
                images = images.to(device)
                rank_targets = rank_targets.to(device)
                suit_targets = suit_targets.to(device)

                rank_preds, suit_preds = model(images)
                loss_rank = criterion_rank(rank_preds, rank_targets)
                loss_suit = criterion_suit(suit_preds, suit_targets)
                val_loss += (loss_rank + loss_suit).item() * images.size(0)

                _, predicted_rank = torch.max(rank_preds, 1)
                _, predicted_suit = torch.max(suit_preds, 1)
                
                rank_correct += (predicted_rank == rank_targets).sum().item()
                suit_correct += (predicted_suit == suit_targets).sum().item()
                total_val += rank_targets.size(0)

        epoch_val_loss = val_loss / max(1, len(val_dataset))
        rank_acc = rank_correct / max(1, total_val)
        suit_acc = suit_correct / max(1, total_val)

        print(f"Epoch {epoch+1:02d}/{epochs:02d} | Train Loss: {epoch_train_loss:.4f} | Val Loss: {epoch_val_loss:.4f} | Rank Acc: {rank_acc*100:.1f}% | Suit Acc: {suit_acc*100:.1f}%", flush=True)

        if epoch_val_loss < best_val_loss:
            best_val_loss = epoch_val_loss
            torch.save(model.state_dict(), "CardDualHeadClassifier.pth")

    print("[SUCCESS] Advanced Training Completed! Loading best model weights...", flush=True)
    model.load_state_dict(torch.load("CardDualHeadClassifier.pth"))
    model.cpu()
    model.eval()

    # Export to CoreML (.mlmodel) for iOS
    print("[EXPORT] Exporting CoreML model for iOS (.mlmodel)...", flush=True)
    example_input = torch.rand(1, 3, 160, 96)
    traced_model = torch.jit.trace(model, example_input)

    scale = 1.0 / (255.0 * 0.226)
    red_bias = -0.485 / 0.229
    green_bias = -0.456 / 0.224
    blue_bias = -0.406 / 0.225

    coreml_model = ct.convert(
        traced_model,
        convert_to="neuralnetwork",
        inputs=[ct.ImageType(name="image", shape=(1, 3, 160, 96), scale=scale, bias=[red_bias, green_bias, blue_bias])],
        outputs=[
            ct.TensorType(name="rank_logits"),
            ct.TensorType(name="suit_logits")
        ]
    )

    ios_target_dir = os.path.join("ios", "CardLink")
    os.makedirs(ios_target_dir, exist_ok=True)
    ios_model_path = os.path.join(ios_target_dir, "CardDualHeadClassifier.mlmodel")
    
    if os.path.exists(ios_model_path):
        os.remove(ios_model_path)
        
    coreml_model.save(ios_model_path)
    print(f"[DONE] Successfully saved CoreML model to: {ios_model_path}", flush=True)

if __name__ == "__main__":
    train_and_export()
