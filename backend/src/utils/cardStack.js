/**
 * Extract raw label string from card item (supports both string "A♠" and object { label: "A♠", image: "..." })
 */
function getCardLabel(cardItem) {
  if (!cardItem) return '';
  if (typeof cardItem === 'string') return cardItem.trim().toUpperCase();
  if (typeof cardItem === 'object' && cardItem.label) return String(cardItem.label).trim().toUpperCase();
  return '';
}

/**
 * Parse card string or object to extract rank and suit
 * e.g., "A♠", "10♥", "KD", "9", "J♣", { label: "A♠", image: "data:..." }
 */
function parseCard(cardItem) {
  const clean = getCardLabel(cardItem);
  if (!clean) {
    return { rank: '', suit: '', value: 0, isFace: false, image: cardItem?.image || null };
  }
  
  // Extract suit if exists (♠, ♥, ♦, ♣ or S, H, D, C)
  let rank = clean;
  let suit = '';
  const lastChar = clean.slice(-1);
  if (['♠', '♥', '♦', '♣', 'S', 'H', 'D', 'C'].includes(lastChar)) {
    suit = lastChar;
    rank = clean.slice(0, -1);
  }

  // Determine value and face card status
  let value = 0;
  let isFace = false;
  let rankWeight = 0; // For Sáp ranking

  switch (rank) {
    case 'A':
      value = 1;
      rankWeight = 14;
      break;
    case 'K':
      value = 10; // 0 modulo 10
      isFace = true;
      rankWeight = 13;
      break;
    case 'Q':
      value = 10;
      isFace = true;
      rankWeight = 12;
      break;
    case 'J':
      value = 10;
      isFace = true;
      rankWeight = 11;
      break;
    case '10':
      value = 10;
      rankWeight = 10;
      break;
    case '9':
      value = 9;
      rankWeight = 9;
      break;
    case '8':
      value = 8;
      rankWeight = 8;
      break;
    case '7':
      value = 7;
      rankWeight = 7;
      break;
    case '6':
      value = 6;
      rankWeight = 6;
      break;
    case '5':
      value = 5;
      rankWeight = 5;
      break;
    case '4':
      value = 4;
      rankWeight = 4;
      break;
    case '3':
      value = 3;
      rankWeight = 3;
      break;
    case '2':
      value = 2;
      rankWeight = 2;
      break;
    default:
      const parsedNum = parseInt(rank, 10);
      if (!isNaN(parsedNum)) {
        value = parsedNum;
        rankWeight = parsedNum;
      }
  }

  return {
    raw: clean,
    rank,
    suit,
    value,
    isFace,
    rankWeight,
    image: (typeof cardItem === 'object' && cardItem.image) ? cardItem.image : null
  };
}

/**
 * Calculate Bai Cao (3-Card) Score for a list of cards
 */
function calculateBaiCaoScore(cards) {
  if (!cards || !Array.isArray(cards) || cards.length === 0) {
    return {
      points: 0,
      rankType: 'EMPTY',
      displayText: 'Chưa có bài',
      weight: -1,
      isSpecial: false
    };
  }

  const parsed = cards.map(parseCard);

  // If column has 1 or 2 cards: show partial score
  if (cards.length < 3) {
    const sum = parsed.reduce((acc, c) => acc + c.value, 0);
    const pts = sum % 10;
    return {
      points: pts,
      rankType: 'PARTIAL',
      displayText: pts === 0 ? 'Bù (Tạm tính)' : `${pts} Điểm (Tạm tính)`,
      weight: pts,
      isSpecial: false
    };
  }

  // Evaluate full 3-card hand (take first 3 cards if more)
  const threeCards = parsed.slice(0, 3);

  // 1. Check SÁP (Three of a Kind: AAA, KKK, 777...)
  const isSap = threeCards[0].rank === threeCards[1].rank && threeCards[1].rank === threeCards[2].rank;
  if (isSap) {
    const sapRank = threeCards[0].rank;
    const sapWeight = 3000 + threeCards[0].rankWeight; // 3000+ for Sáp
    return {
      points: 10,
      rankType: 'SAP',
      displayText: `Sáp ${sapRank}`,
      weight: sapWeight,
      isSpecial: true
    };
  }

  // 2. Check BA TÂY / BA TIÊN (3 Face Cards: J, Q, K)
  const isBaTay = threeCards.every((c) => c.isFace);
  if (isBaTay) {
    return {
      points: 10,
      rankType: 'BA_TAY',
      displayText: 'Ba Tây',
      weight: 2000, // 2000 for Ba Tây
      isSpecial: true
    };
  }

  // 3. Normal Points (Nút / Modulo 10)
  const sum = threeCards.reduce((acc, c) => acc + c.value, 0);
  const pts = sum % 10;

  if (pts === 0) {
    return {
      points: 0,
      rankType: 'BU',
      displayText: 'Bù (0 Điểm)',
      weight: 0,
      isSpecial: false
    };
  }

  return {
    points: pts,
    rankType: 'DIEM',
    displayText: `${pts} Điểm`,
    weight: 100 + pts, // 100-109 for regular points
    isSpecial: pts === 9
  };
}

/**
 * Get all columns with calculated Bài Cào scores and winner indicators
 */
function getColumnsWithScores(cardStack) {
  if (!Array.isArray(cardStack)) return [];

  const columns = cardStack.map((cards, idx) => {
    const score = calculateBaiCaoScore(cards);
    return {
      columnIndex: idx,
      cards: cards || [],
      score: score,
      isWinner: false
    };
  });

  let maxWeight = -1;
  columns.forEach((col) => {
    if (col.score.weight > maxWeight && col.score.rankType !== 'EMPTY') {
      maxWeight = col.score.weight;
    }
  });

  if (maxWeight > 0) {
    columns.forEach((col) => {
      if (col.score.weight === maxWeight) {
        col.isWinner = true;
      }
    });
  }

  return columns;
}

/**
 * Check if a card already exists anywhere in the active card stack
 */
function isCardAlreadyInStack(cardStack, item) {
  if (!Array.isArray(cardStack)) return false;
  const label = getCardLabel(item);
  return cardStack.some((col) =>
    Array.isArray(col) && col.some((c) => getCardLabel(c) === label)
  );
}

/**
 * Initialize empty cardStack array of N rounds
 */
function createInitialCardStack(rounds = 3) {
  const count = Math.max(2, Math.min(9, rounds));
  const stack = [];
  for (let i = 0; i < count; i++) {
    stack.push([]);
  }
  return stack;
}

/**
 * Add a card item to the cardStack in round-robin order with 52-card uniqueness check
 */
function appendCardToStack(cardStack, cardCount, rounds, item) {
  if (!Array.isArray(cardStack) || cardStack.length === 0) {
    cardStack = createInitialCardStack(rounds);
  }

  // 1. Deck Uniqueness Integrity: Reject duplicate cards
  if (isCardAlreadyInStack(cardStack, item)) {
    return {
      newStack: cardStack,
      newCount: cardCount,
      skipped: true,
      reason: 'DUPLICATE_CARD_IN_DECK',
      columnsWithScores: getColumnsWithScores(cardStack)
    };
  }

  const totalRounds = rounds || cardStack.length;

  let targetColumn = -1;
  for (let i = 0; i < totalRounds; i++) {
    const colIndex = (cardCount + i) % totalRounds;
    if (!cardStack[colIndex] || cardStack[colIndex].length < 3) {
      targetColumn = colIndex;
      break;
    }
  }

  if (targetColumn === -1) {
    targetColumn = cardCount % totalRounds;
  }

  const newStack = cardStack.map((col) => (Array.isArray(col) ? [...col] : []));
  while (newStack.length <= targetColumn) {
    newStack.push([]);
  }

  newStack[targetColumn].push(item);
  const newCount = cardCount + 1;

  return {
    newStack,
    newCount,
    columnIndex: targetColumn,
    skipped: false,
    columnsWithScores: getColumnsWithScores(newStack)
  };
}

module.exports = {
  getCardLabel,
  parseCard,
  calculateBaiCaoScore,
  getColumnsWithScores,
  isCardAlreadyInStack,
  createInitialCardStack,
  appendCardToStack
};
