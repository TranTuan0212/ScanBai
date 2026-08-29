const test = require('node:test');
const assert = require('node:assert');
const { calculateBaiCaoScore, getColumnsWithScores } = require('../src/utils/cardStack');

test('calculateBaiCaoScore detects Sáp correctly', () => {
  const sapA = calculateBaiCaoScore(['A♠', 'A♥', 'A♦']);
  assert.strictEqual(sapA.rankType, 'SAP');
  assert.strictEqual(sapA.displayText, 'Sáp A');
  assert.strictEqual(sapA.isSpecial, true);

  const sap8 = calculateBaiCaoScore(['8♣', '8♦', '8♠']);
  assert.strictEqual(sap8.rankType, 'SAP');
  assert.strictEqual(sap8.displayText, 'Sáp 8');
  assert.ok(sapA.weight > sap8.weight); // Sáp A > Sáp 8
});

test('calculateBaiCaoScore detects Ba Tây / Ba Tiên correctly', () => {
  const baTay = calculateBaiCaoScore(['J♠', 'Q♥', 'K♦']);
  assert.strictEqual(baTay.rankType, 'BA_TAY');
  assert.strictEqual(baTay.displayText, 'Ba Tây');
  assert.strictEqual(baTay.isSpecial, true);

  const sap2 = calculateBaiCaoScore(['2♠', '2♥', '2♦']);
  assert.ok(sap2.weight > baTay.weight); // Sáp > Ba Tây
});

test('calculateBaiCaoScore calculates standard 9 Điểm, 8 Điểm, and Bù', () => {
  const chinDiem = calculateBaiCaoScore(['3♠', '6♥', 'K♦']); // 3 + 6 + 10 = 19 % 10 = 9
  assert.strictEqual(chinDiem.rankType, 'DIEM');
  assert.strictEqual(chinDiem.points, 9);
  assert.strictEqual(chinDiem.displayText, '9 Điểm');

  const tamDiem = calculateBaiCaoScore(['4♠', '4♥', '10♦']); // 4 + 4 + 10 = 18 % 10 = 8
  assert.strictEqual(tamDiem.rankType, 'DIEM');
  assert.strictEqual(tamDiem.points, 8);
  assert.strictEqual(tamDiem.displayText, '8 Điểm');

  const bu = calculateBaiCaoScore(['10♠', 'K♥', 'Q♦']); // 10 + 10 + 10 = 30 % 10 = 0 (not face cards because 10 is not face)
  assert.strictEqual(bu.rankType, 'BU');
  assert.strictEqual(bu.points, 0);
  assert.strictEqual(bu.displayText, 'Bù (0 Điểm)');
});

test('calculateBaiCaoScore handles partial hands (1 and 2 cards)', () => {
  const oneCard = calculateBaiCaoScore(['7♠']);
  assert.strictEqual(oneCard.rankType, 'PARTIAL');
  assert.strictEqual(oneCard.points, 7);

  const twoCards = calculateBaiCaoScore(['7♠', '8♥']); // 15 % 10 = 5
  assert.strictEqual(twoCards.rankType, 'PARTIAL');
  assert.strictEqual(twoCards.points, 5);
});

test('getColumnsWithScores assigns winner correctly', () => {
  const stack = [
    ['3♠', '5♥', '10♦'], // 8 Điểm
    ['J♠', 'Q♥', 'K♦'],   // Ba Tây (Winner)
    ['A♠', '9♥', '9♦']    // 9 Điểm
  ];

  const columns = getColumnsWithScores(stack);
  assert.strictEqual(columns.length, 3);
  assert.strictEqual(columns[0].isWinner, false);
  assert.strictEqual(columns[1].isWinner, true); // Ba Tây thắng 9 Điểm
  assert.strictEqual(columns[2].isWinner, false);
});
