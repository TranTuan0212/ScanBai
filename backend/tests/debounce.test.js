const test = require('node:test');
const assert = require('node:assert');

class HighSpeedCardDebounce {
  constructor(confThreshold = 0.75, highConf = 0.85, requiredFrames = 2, timeoutMs = 1200) {
    this.confThreshold = confThreshold;
    this.highConf = highConf;
    this.requiredFrames = requiredFrames;
    this.timeoutMs = timeoutMs;
    this.state = { type: 'NoCard' };
    this.recentDetections = [];
    this.emittedCards = [];
  }

  processDetection(detection) {
    if (this.recentDetections.length >= 4) {
      this.recentDetections.shift();
    }
    this.recentDetections.push(detection);

    const valid = detection && detection.confidence >= this.confThreshold ? detection : null;
    const label = valid ? valid.label : null;

    if (label) {
      const count = this.recentDetections.filter(d => d && d.label === label && d.confidence >= this.confThreshold).length;
      const isUltraHigh = valid.confidence >= this.highConf;

      const isConfirmed = (count >= this.requiredFrames) || (isUltraHigh && count >= 2);

      if (isConfirmed) {
        if (this.state.type === 'NoCard') {
          this.state = { type: 'CardActive', label };
          this.emittedCards.push(label);
        } else if (this.state.type === 'CardActive' && this.state.label !== label) {
          this.state = { type: 'CardActive', label };
          this.emittedCards.push(label);
        }
      }
    }
  }

  simulateTimeout() {
    this.state = { type: 'NoCard' };
    this.recentDetections = [];
  }
}

test('HighSpeedCardDebounce catches fast deals in 2 frames (~60ms)', () => {
  const debounce = new HighSpeedCardDebounce();

  // Fast deal card "A♠" (2 frames at 30fps = 66ms)
  debounce.processDetection({ label: 'A♠', confidence: 0.88 });
  debounce.processDetection({ label: 'A♠', confidence: 0.90 });

  assert.strictEqual(debounce.emittedCards.length, 1);
  assert.strictEqual(debounce.emittedCards[0], 'A♠');
});

test('HighSpeedCardDebounce handles rapid card sequence without delay', () => {
  const debounce = new HighSpeedCardDebounce();

  // Deal 1st card: "A♠"
  debounce.processDetection({ label: 'A♠', confidence: 0.90 });
  debounce.processDetection({ label: 'A♠', confidence: 0.90 });

  // Rapidly deal 2nd card: "K♥" (different card switches immediately)
  debounce.processDetection({ label: 'K♥', confidence: 0.88 });
  debounce.processDetection({ label: 'K♥', confidence: 0.92 });

  // Rapidly deal 3rd card: "9♦"
  debounce.processDetection({ label: '9♦', confidence: 0.87 });
  debounce.processDetection({ label: '9♦', confidence: 0.91 });

  assert.strictEqual(debounce.emittedCards.length, 3);
  assert.deepStrictEqual(debounce.emittedCards, ['A♠', 'K♥', '9♦']);
});

test('HighSpeedCardDebounce ignores single isolated noise glitch', () => {
  const debounce = new HighSpeedCardDebounce();

  // Single glitch frame
  debounce.processDetection({ label: '7♣', confidence: 0.76 });
  debounce.processDetection(null);

  assert.strictEqual(debounce.emittedCards.length, 0);
});
