const test = require('node:test');
const assert = require('node:assert');
const { createInitialCardStack, appendCardToStack } = require('../src/utils/cardStack');

test('createInitialCardStack initializes N empty arrays', () => {
  const stack3 = createInitialCardStack(3);
  assert.strictEqual(stack3.length, 3);
  assert.deepStrictEqual(stack3, [[], [], []]);

  const stack5 = createInitialCardStack(5);
  assert.strictEqual(stack5.length, 5);
  assert.deepStrictEqual(stack5, [[], [], [], [], []]);
});

test('appendCardToStack correctly distributes A, B, C, D, E for N=3', () => {
  let stack = createInitialCardStack(3);
  let count = 0;
  const rounds = 3;

  const cards = ['A', 'B', 'C', 'D', 'E'];
  for (const card of cards) {
    const result = appendCardToStack(stack, count, rounds, card);
    stack = result.newStack;
    count = result.newCount;
  }

  assert.strictEqual(count, 5);
  // Expected: [[A, D], [B, E], [C]]
  assert.deepStrictEqual(stack, [
    ['A', 'D'],
    ['B', 'E'],
    ['C']
  ]);
});
