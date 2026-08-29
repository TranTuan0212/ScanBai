import React, { useState, useEffect, useRef } from 'react';
import { io } from 'socket.io-client';
import client, { getBaseUrl } from '../api/client';
import {
  Tv,
  Radio,
  Eye,
  Trophy,
  RefreshCw,
  Layers,
  Sparkles,
  Play,
  Camera,
  X,
  RotateCcw,
  Sliders,
  Maximize2,
  ZoomIn,
  CheckCircle2
} from 'lucide-react';

/**
 * Extract raw label string from card item
 */
function getCardLabel(cardItem) {
  if (!cardItem) return '';
  if (typeof cardItem === 'string') return cardItem.trim().toUpperCase();
  if (typeof cardItem === 'object' && cardItem.label) return String(cardItem.label).trim().toUpperCase();
  return '';
}

function parseCard(cardItem) {
  if (!cardItem) return { raw: '', rank: '', suit: '', value: 0, isFace: false, isRed: false, image: null };

  let item = cardItem;
  if (typeof cardItem === 'string') {
    const trimmed = cardItem.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        item = JSON.parse(trimmed);
      } catch (_) {}
    } else if (trimmed.startsWith('data:image/')) {
      return { raw: 'Ảnh Chụp', rank: '', suit: '', value: 0, isFace: false, isRed: false, image: trimmed };
    }
  }

  let raw = '';
  let image = null;

  if (typeof item === 'object' && item !== null) {
    raw = item.label || item.raw || item.name || '';
    image = item.image || item.cardImage || item.photo || item.frame || null;
  } else if (typeof item === 'string') {
    raw = item;
  }

  const clean = String(raw).trim();
  if (!clean && image) {
    return { raw: 'Ảnh Chụp', rank: '', suit: '', value: 0, isFace: false, isRed: false, image };
  }
  if (!clean) {
    return { raw: '', rank: '', suit: '', value: 0, isFace: false, isRed: false, image: null };
  }

  let rank = clean;
  let suit = '';

  const lastChar = clean.slice(-1);
  if (['♠', '♥', '♦', '♣', 'S', 'H', 'D', 'C'].includes(lastChar)) {
    suit = lastChar;
    rank = clean.slice(0, -1);
  }

  let value = 0;
  let isFace = false;
  let rankWeight = 0;

  switch (rank) {
    case 'A':
      value = 1;
      rankWeight = 14;
      break;
    case 'K':
      value = 10;
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
    default:
      const num = parseInt(rank, 10) || 0;
      value = num;
      rankWeight = num;
      break;
  }

  const isRed = suit === '♥' || suit === '♦' || suit === 'H' || suit === 'D';
  const suitSymbol = suit === 'H' ? '♥' : suit === 'D' ? '♦' : suit === 'S' ? '♠' : suit === 'C' ? '♣' : suit || '';

  return { raw: clean, rank, suit: suitSymbol, value, isFace, rankWeight, isRed, image };
}

function calculateBaiCaoScore(cards) {
  if (!cards || cards.length === 0) {
    return { points: 0, rankType: 'EMPTY', text: 'Chờ chia bài', weight: -1, isSpecial: false };
  }

  const parsed = cards.map(parseCard);

  if (cards.length < 3) {
    const sum = parsed.reduce((acc, c) => acc + c.value, 0);
    const pts = sum % 10;
    return {
      points: pts,
      rankType: 'PARTIAL',
      text: pts === 0 ? 'Bù (Tạm tính)' : `${pts} Điểm (Tạm)`,
      weight: pts,
      isSpecial: false
    };
  }

  const three = parsed.slice(0, 3);

  // 1. Sáp
  if (three[0].rank === three[1].rank && three[1].rank === three[2].rank) {
    return {
      points: 10,
      rankType: 'SAP',
      text: `🔥 Sáp ${three[0].rank}`,
      weight: 3000 + three[0].rankWeight,
      isSpecial: true
    };
  }

  // 2. Ba Tây
  if (three.every((c) => c.isFace)) {
    return {
      points: 10,
      rankType: 'BA_TAY',
      text: '👑 Ba Tây',
      weight: 2000,
      isSpecial: true
    };
  }

  // 3. Modulo 10 Points
  const sum = three.reduce((acc, c) => acc + c.value, 0);
  const pts = sum % 10;

  if (pts === 0) {
    return { points: 0, rankType: 'BU', text: '0 Điểm (Bù)', weight: 0, isSpecial: false };
  }

  return {
    points: pts,
    rankType: 'DIEM',
    text: pts >= 8 ? `⭐ ${pts} Điểm` : `${pts} Điểm`,
    weight: 100 + pts,
    isSpecial: pts === 9
  };
}

export default function LiveViewer() {
  const [sessions, setSessions] = useState([]);
  const [selectedSession, setSelectedSession] = useState(null);
  const [cardStack, setCardStack] = useState([]);
  const [viewerCount, setViewerCount] = useState(0);
  const [isLoading, setIsLoading] = useState(false);
  const [lastDetectedCard, setLastDetectedCard] = useState(null);
  const [previewSnapshot, setPreviewSnapshot] = useState(null);
  const [liveFrame, setLiveFrame] = useState(null);
  const [viewMode, setViewMode] = useState('grid'); // 'grid' (12 slots) or 'columns' (tụ)
  const [sliderSpeed, setSliderSpeed] = useState(50);
  const socketRef = useRef(null);

  // 1. Polling for active sessions
  const fetchActiveSessions = async () => {
    try {
      const res = await client.get('/sessions/active');
      setSessions(res.data);
      if (res.data.length > 0) {
        setSelectedSession((prev) => {
          if (!prev || !res.data.some((s) => s.sessionId === prev.sessionId)) {
            return res.data[0];
          }
          return prev;
        });
      } else {
        setSelectedSession(null);
      }
    } catch (err) {
      console.error('Failed to load active sessions:', err);
    }
  };

  useEffect(() => {
    fetchActiveSessions();
    const interval = setInterval(fetchActiveSessions, 2000);
    return () => clearInterval(interval);
  }, []);

  // 2. Connect Socket.IO to live stream channel
  useEffect(() => {
    const token = localStorage.getItem('admin_token');
    const baseUrl = getBaseUrl().replace('/api', '');

    const socket = io(baseUrl, {
      auth: { token },
      transports: ['websocket', 'polling']
    });
    socketRef.current = socket;

    socket.on('connect', () => {
      if (selectedSession) {
        console.log('[Web Viewer] Joined room:', selectedSession.sessionId);
        socket.emit('join_room', selectedSession.sessionId);
      }
    });

    socket.on('live_frame', (frame) => {
      setLiveFrame(frame);
      setSelectedSession((prev) => {
        if (!prev) {
          return {
            sessionId: 'active_live_stream',
            broadcasterEmail: 'iPhone Broadcaster (Trực Tiếp)',
            rounds: 3
          };
        }
        return prev;
      });
    });

    socket.on('card_detected', (data) => {
      const { label, imageBase64 } = data || {};
      if (label || imageBase64) {
        const newCard = {
          label: label || 'LÁ BÀI SẮC NÉT',
          image: imageBase64 ? (imageBase64.startsWith('data:') ? imageBase64 : `data:image/jpeg;base64,${imageBase64}`) : null
        };
        setCardStack((prev) => {
          const next = [...prev];
          if (next.length === 0) next.push([]);
          const currentCol = next[next.length - 1];
          if (currentCol.length >= 3) {
            next.push([newCard]);
          } else {
            currentCol.push(newCard);
          }
          return next;
        });
        setLastDetectedCard(parseCard(newCard));
      }
    });

    socket.on('card_state', (newStack) => {
      const parsedStack = Array.isArray(newStack) ? newStack : JSON.parse(newStack || '[]');
      setCardStack(parsedStack);

      const allCards = parsedStack.flat();
      if (allCards.length > 0) {
        const last = allCards[allCards.length - 1];
        setLastDetectedCard(parseCard(last));
      }
    });

    socket.on('viewer_count', (count) => {
      setViewerCount(count);
    });

    socket.on('live_ended', () => {
      setLiveFrame(null);
      fetchActiveSessions();
    });

    return () => {
      socket.emit('leave_room', selectedSession.sessionId);
      socket.disconnect();
    };
  }, [selectedSession]);

  // Reset round
  const handleResetStack = () => {
    if (socketRef.current && selectedSession) {
      socketRef.current.emit('reset_stack', selectedSession.sessionId);
      setCardStack([]);
      setLastDetectedCard(null);
    }
  };

  // Demo simulation matching the screenshot (12 card slots)
  const runDemoSimulation = () => {
    const demoSession = {
      sessionId: 'demo-session',
      broadcasterEmail: 'demo@cardlink.com',
      rounds: 4,
      streamId: 'stream_demo_123'
    };
    setSelectedSession(demoSession);

    const demoCards = [
      ['A♠', '9♥', 'K♦'], // Tụ 1
      ['K♠', 'Q♥', 'J♦'], // Tụ 2
      ['7♥', '8♦', '4♠'], // Tụ 3
      ['3♠', '3♥']         // Tụ 4
    ];
    setCardStack(demoCards);
    setViewerCount(8);
    setLastDetectedCard({ raw: '3♥', rank: '3', suit: '♥', isRed: true, image: null });
  };

  const rounds = selectedSession?.rounds || 4;
  const maxSlots = Math.max(12, rounds * 3);

  // Flatten card items in order of deal
  const flattenedCards = [];
  const maxCardsPerCol = Math.max(...(cardStack.map((c) => c.length) || [0]), 3);

  for (let cardIdx = 0; cardIdx < maxCardsPerCol; cardIdx++) {
    for (let roundIdx = 0; roundIdx < rounds; roundIdx++) {
      if (cardStack[roundIdx] && cardStack[roundIdx][cardIdx]) {
        flattenedCards.push({
          card: parseCard(cardStack[roundIdx][cardIdx]),
          roundIdx: roundIdx + 1,
          cardIdx: cardIdx + 1
        });
      }
    }
  }

  // Create slot array of size maxSlots
  const slots = Array.from({ length: maxSlots }, (_, i) => {
    const item = flattenedCards[i] || null;
    return {
      slotNumber: i + 1,
      item
    };
  });

  const safeStack = cardStack.length >= rounds ? cardStack : Array.from({ length: rounds }, (_, i) => cardStack[i] || []);
  const evaluatedColumns = safeStack.map((cards, idx) => {
    const score = calculateBaiCaoScore(cards);
    return { columnIndex: idx, cards: cards || [], score };
  });

  let maxWeight = -1;
  evaluatedColumns.forEach((col) => {
    if (col.score.weight > maxWeight && col.score.rankType !== 'EMPTY') {
      maxWeight = col.score.weight;
    }
  });

  const finalColumns = evaluatedColumns.map((col) => ({
    ...col,
    isWinner: maxWeight > 0 && col.score.weight === maxWeight && col.cards.length > 0
  }));

  return (
    <div className="space-y-4">
      {/* Modal for Enlarged Snapshot */}
      {previewSnapshot && (
        <div
          className="fixed inset-0 z-50 bg-black/85 backdrop-blur-sm flex items-center justify-center p-4"
          onClick={() => setPreviewSnapshot(null)}
        >
          <div
            className="bg-slate-900 border border-slate-700 rounded-2xl p-5 max-w-lg w-full shadow-2xl relative space-y-4"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Camera className="w-5 h-5 text-indigo-400" />
                <h3 className="text-sm font-bold text-white">Ảnh Chụp Thực Tế Từ Camera</h3>
              </div>
              <button
                onClick={() => setPreviewSnapshot(null)}
                className="p-1 text-slate-400 hover:text-white rounded-lg"
              >
                <X className="w-5 h-5" />
              </button>
            </div>
            <img
              src={previewSnapshot}
              alt="Live Snapshot"
              className="w-full h-auto max-h-[70vh] object-contain rounded-xl border border-slate-700 shadow-inner"
            />
            <p className="text-xs text-slate-400 text-center">
              Khung hình ảnh chụp gốc từ lúc người chia lướt lá bài ra khỏi bộ bài.
            </p>
          </div>
        </div>
      )}

      {/* Top Header Control Bar */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-3 bg-slate-900/90 p-4 rounded-2xl border border-slate-800 shadow-xl">
        <div className="flex items-center space-x-3">
          <div className="p-2.5 bg-red-500/10 rounded-xl border border-red-500/30">
            <Tv className="w-6 h-6 text-red-500 animate-pulse" />
          </div>
          <div>
            <h1 className="text-lg font-black text-white flex items-center gap-2">
              Hệ Thống Giám Sát & Bảng Khung Ảnh Chia Bài
              <span className="text-[10px] bg-red-600 text-white font-black px-2 py-0.5 rounded-full uppercase tracking-wider">
                PRO MONITOR
              </span>
            </h1>
            <p className="text-xs text-slate-400">Tự động chụp và hiển thị từng khung ảnh rút lá bài từ bộ bài</p>
          </div>
        </div>

        {/* Action Controls */}
        <div className="flex items-center gap-2.5">
          <select
            value={selectedSession?.sessionId || ''}
            onChange={(e) => {
              const found = sessions.find((s) => s.sessionId === e.target.value);
              setSelectedSession(found);
              setLiveFrame(null);
            }}
            className="bg-slate-950 text-white border border-slate-700 text-xs rounded-xl px-3.5 py-2 focus:ring-2 focus:ring-red-500 focus:outline-none"
          >
            {sessions.length === 0 ? (
              <option value="">(Chưa có phiên Live nào)</option>
            ) : (
              sessions.map((s, idx) => (
                <option key={s.sessionId} value={s.sessionId}>
                  Phòng #{idx + 1}: {s.broadcasterEmail} ({s.rounds} Tụ)
                </option>
              ))
            )}
          </select>

          <button
            onClick={fetchActiveSessions}
            className="p-2 bg-slate-800 hover:bg-slate-700 text-slate-300 rounded-xl transition border border-slate-700"
            title="Làm mới danh sách phòng"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${isLoading ? 'animate-spin' : ''}`} />
          </button>

          <button
            onClick={handleResetStack}
            className="flex items-center gap-1 px-3 py-2 bg-rose-600/20 hover:bg-rose-600/30 text-rose-300 border border-rose-500/30 text-xs font-bold rounded-xl transition"
            title="Xóa tất cả các khung ảnh để bắt đầu ván chia bài mới"
          >
            <RotateCcw className="w-3.5 h-3.5" />
            <span>Ván Mới</span>
          </button>

          <button
            onClick={runDemoSimulation}
            className="flex items-center gap-1 px-3 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-bold rounded-xl transition shadow"
          >
            <Sparkles className="w-3.5 h-3.5" />
            <span>Mô Phỏng Demo</span>
          </button>
        </div>
      </div>

      {/* Main Split Layout: Left Card Gallery (68%) + Right Dual Video Monitor (32%) */}
      {!selectedSession ? (
        <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-12 text-center text-slate-400 space-y-4">
          <Radio className="w-16 h-16 mx-auto text-red-500/80 animate-pulse" />
          <h3 className="text-xl font-bold text-white">Chờ Người Phát Bắt Đầu Live...</h3>
          <p className="text-sm text-slate-300 max-w-lg mx-auto">
            Mở app trên điện thoại và bấm <b className="text-red-400">"Phát Live"</b>.
            Các khung ảnh rút bài và camera sẽ lập tức xuất hiện trực tiếp trên màn hình này!
          </p>
          <div className="pt-2">
            <button
              onClick={runDemoSimulation}
              className="inline-flex items-center gap-2 px-5 py-2.5 bg-indigo-600 hover:bg-indigo-500 text-white font-bold rounded-xl text-sm transition shadow-lg"
            >
              <Play className="w-4 h-4" />
              <span>Xem Thử Giao Diện Mẫu (12 Khung Ảnh)</span>
            </button>
          </div>
        </div>
      ) : (
        <div className="grid grid-cols-1 xl:grid-cols-12 gap-4">
          {/* ================= LEFT PANEL: 12 CARD SNAPSHOT GALLERY (7 COLS) ================= */}
          <div className="xl:col-span-7 bg-slate-900/90 border border-slate-800 rounded-2xl p-4 shadow-xl flex flex-col space-y-3">
            {/* Top Toolbar */}
            <div className="flex items-center justify-between border-b border-slate-800 pb-3">
              <div className="flex items-center gap-2">
                <Layers className="w-4 h-4 text-indigo-400" />
                <h2 className="text-sm font-black text-white uppercase tracking-wider">
                  Khung Ảnh Rút Bài Theo Thứ Tự ({flattenedCards.length}/{maxSlots} Lá)
                </h2>
              </div>
              <div className="flex items-center gap-2">
                <button
                  onClick={() => setViewMode('grid')}
                  className={`px-2.5 py-1 text-xs font-bold rounded-lg transition ${
                    viewMode === 'grid' ? 'bg-indigo-600 text-white' : 'bg-slate-800 text-slate-400'
                  }`}
                >
                  Lưới 12 Lá
                </button>
                <button
                  onClick={() => setViewMode('columns')}
                  className={`px-2.5 py-1 text-xs font-bold rounded-lg transition ${
                    viewMode === 'columns' ? 'bg-indigo-600 text-white' : 'bg-slate-800 text-slate-400'
                  }`}
                >
                  Theo Tụ ({rounds} Tụ)
                </button>
              </div>
            </div>

            {/* View Mode 1: 12-Slot Responsive Gallery (Exact match to monitor photo) */}
            {viewMode === 'grid' ? (
              <div className="grid grid-cols-3 sm:grid-cols-4 gap-2.5 flex-1">
                {slots.map((slot) => {
                  const card = slot.item?.card;
                  const hasPhoto = card && card.image;

                  return (
                    <div
                      key={slot.slotNumber}
                      onClick={() => hasPhoto && setPreviewSnapshot(card.image)}
                      className={`relative aspect-[4/5] rounded-xl border flex flex-col items-center justify-between overflow-hidden transition-all duration-200 ${
                        slot.item
                          ? 'bg-slate-950 border-indigo-500/60 shadow-lg cursor-pointer hover:scale-[1.02]'
                          : 'bg-slate-950/40 border-slate-800/80'
                      }`}
                    >
                      {/* Slot Index Badge (1..12) in top-left */}
                      <div className="absolute top-1.5 left-1.5 z-10 bg-black/70 backdrop-blur-sm text-slate-300 text-[10px] font-black px-1.5 py-0.5 rounded-md border border-white/10">
                        #{slot.slotNumber}
                      </div>

                      {/* Tụ Tag in top-right if dealt */}
                      {slot.item && (
                        <div className="absolute top-1.5 right-1.5 z-10 bg-indigo-600/90 text-white text-[10px] font-bold px-1.5 py-0.5 rounded-md shadow">
                          Tụ {slot.item.roundIdx}
                        </div>
                      )}

                      {/* Center Content: Real Camera Snapshot Photo OR Empty Slot Placeholder */}
                      {slot.item ? (
                        hasPhoto ? (
                          <img
                            src={card.image}
                            alt={`Card ${slot.slotNumber}`}
                            className="w-full h-full object-cover"
                          />
                        ) : (
                          <div className="w-full h-full flex flex-col items-center justify-center p-2 bg-gradient-to-b from-slate-900 to-slate-950">
                            <span
                              className={`text-2xl font-black ${
                                card.isRed ? 'text-red-500' : 'text-slate-100'
                              }`}
                            >
                              {card.rank}
                            </span>
                            <span
                              className={`text-xl font-bold ${
                                card.isRed ? 'text-red-500' : 'text-slate-100'
                              }`}
                            >
                              {card.suit}
                            </span>
                          </div>
                        )
                      ) : (
                        <div className="w-full h-full flex flex-col items-center justify-center text-slate-700">
                          <span className="text-xl font-black text-slate-700/80">{slot.slotNumber}</span>
                          <span className="text-[10px] text-slate-600">Trống</span>
                        </div>
                      )}

                      {/* Bottom Detected Label Badge */}
                      {slot.item && (
                        <div className="absolute bottom-1 left-1 right-1 z-10 bg-black/80 backdrop-blur-md px-1.5 py-0.5 rounded-md flex items-center justify-between border border-white/10">
                          <span
                            className={`text-xs font-black ${
                              card.isRed ? 'text-red-400' : 'text-slate-200'
                            }`}
                          >
                            {card.raw || `${card.rank}${card.suit}`}
                          </span>
                          <span className="text-[9px] text-slate-400">Lá {slot.item.cardIdx}</span>
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            ) : (
              /* View Mode 2: Bài Cào Column View */
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 flex-1">
                {finalColumns.map((col) => (
                  <div
                    key={col.columnIndex}
                    className={`rounded-xl p-3 border flex flex-col items-center space-y-2 ${
                      col.isWinner
                        ? 'bg-amber-950/20 border-amber-400/80 shadow-lg'
                        : 'bg-slate-950 border-slate-800'
                    }`}
                  >
                    <div
                      className={`w-full text-center py-1 rounded-md text-xs font-black ${
                        col.isWinner ? 'bg-amber-500 text-slate-950' : 'bg-slate-800 text-slate-300'
                      }`}
                    >
                      TỤ {col.columnIndex + 1}
                    </div>

                    <div className="w-full text-center py-0.5 px-1.5 bg-indigo-950/60 border border-indigo-500/30 rounded text-[11px] font-black text-indigo-300">
                      {col.score.text}
                    </div>

                    <div className="w-full space-y-2 flex-1">
                      {col.cards.length === 0 ? (
                        <div className="h-28 border border-dashed border-slate-800 rounded-lg flex items-center justify-center text-xs text-slate-600">
                          Chờ bài...
                        </div>
                      ) : (
                        col.cards.map((cItem, cIdx) => {
                          const card = parseCard(cItem);
                          return (
                            <div
                              key={cIdx}
                              onClick={() => card.image && setPreviewSnapshot(card.image)}
                              className={`bg-white rounded-lg p-1.5 shadow flex items-center justify-between border border-slate-300 ${
                                card.image ? 'cursor-pointer hover:border-indigo-500' : ''
                              }`}
                            >
                              <div className="flex items-center gap-1.5">
                                {card.image && (
                                  <img
                                    src={card.image}
                                    alt="Snap"
                                    className="w-7 h-7 object-cover rounded border border-slate-400"
                                  />
                                )}
                                <span
                                  className={`text-sm font-black ${
                                    card.isRed ? 'text-red-600' : 'text-slate-900'
                                  }`}
                                >
                                  {card.rank}
                                </span>
                              </div>
                              <span
                                className={`text-base font-bold ${
                                  card.isRed ? 'text-red-600' : 'text-slate-900'
                                }`}
                              >
                                {card.suit}
                              </span>
                            </div>
                          );
                        })
                      )}
                    </div>
                  </div>
                ))}
              </div>
            )}

            {/* Bottom Slider & Stats Bar */}
            <div className="flex items-center justify-between pt-2 border-t border-slate-800 text-xs text-slate-400">
              <div className="flex items-center gap-2">
                <Sliders className="w-3.5 h-3.5 text-indigo-400" />
                <span>Độ nhạy quét:</span>
                <input
                  type="range"
                  min="10"
                  max="100"
                  value={sliderSpeed}
                  onChange={(e) => setSliderSpeed(Number(e.target.value))}
                  className="w-24 h-1.5 bg-slate-700 rounded-lg appearance-none cursor-pointer accent-indigo-500"
                />
                <span className="font-bold text-slate-300">{sliderSpeed}%</span>
              </div>

              <div className="flex items-center gap-3">
                <span>Tổng lá đã chia: <b className="text-amber-400">{flattenedCards.length}</b></span>
                <span>Phòng: <b className="text-indigo-400">{selectedSession.rounds} Tụ</b></span>
              </div>
            </div>
          </div>

          {/* ================= RIGHT PANEL: DUAL LIVE MONITORS (5 COLS) ================= */}
          <div className="xl:col-span-5 space-y-4">
            {/* 1. Top Right Monitor: Real-Time Live Video Feed */}
            <div className="bg-slate-900/90 border border-slate-800 rounded-2xl p-4 shadow-xl space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <span className="relative flex h-2.5 w-2.5">
                    <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-red-400 opacity-75"></span>
                    <span className="relative inline-flex rounded-full h-2.5 w-2.5 bg-red-500"></span>
                  </span>
                  <span className="text-red-500 font-black text-xs uppercase tracking-wider">
                    CAMERA TRỰC TIẾP (LIVE)
                  </span>
                </div>
                <div className="flex items-center gap-1 bg-slate-950 px-2.5 py-0.5 rounded-full text-[11px] font-semibold text-slate-300 border border-slate-800">
                  <Eye className="w-3 h-3 text-indigo-400" />
                  <span>{viewerCount} người xem</span>
                </div>
              </div>

              {/* Video Player Box */}
              <div className="relative aspect-video bg-black rounded-xl overflow-hidden border border-slate-800 flex flex-col items-center justify-center shadow-inner">
                {liveFrame ? (
                  <img
                    src={liveFrame}
                    alt="Live Camera Feed"
                    className="w-full h-full object-cover"
                  />
                ) : (
                  <div className="flex flex-col items-center justify-center p-4 text-center">
                    <Radio className="w-10 h-10 text-red-500 mb-2 animate-pulse" />
                    <span className="text-xs font-semibold text-slate-300">Đang nhận luồng Live từ điện thoại...</span>
                    <span className="text-[10px] text-slate-500 truncate max-w-xs">{selectedSession.streamId}</span>
                  </div>
                )}

                {lastDetectedCard && (
                  <div className="absolute bottom-2 left-2 right-2 bg-indigo-950/90 border border-indigo-500/50 backdrop-blur-md rounded-lg px-2.5 py-1 flex items-center justify-between text-xs text-indigo-200 shadow">
                    <span className="flex items-center gap-1">
                      <Camera className="w-3 h-3 text-amber-400" />
                      <span>Vừa quét:</span>
                    </span>
                    <span className="font-black text-amber-300 text-sm">{lastDetectedCard.raw}</span>
                  </div>
                )}
              </div>
            </div>

            {/* 2. Bottom Right Monitor: Last Card Zoom / Bài Cào Leaderboard */}
            <div className="bg-slate-900/90 border border-slate-800 rounded-2xl p-4 shadow-xl space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-1.5">
                  <ZoomIn className="w-4 h-4 text-amber-400" />
                  <h3 className="text-xs font-black text-white uppercase tracking-wider">
                    Khung Ảnh Rút Gần Nhất & Bảng Điểm
                  </h3>
                </div>

                {finalColumns.find((c) => c.isWinner) && (
                  <div className="flex items-center gap-1 bg-amber-500/10 text-amber-300 border border-amber-500/30 px-2 py-0.5 rounded-full text-[10px] font-black">
                    <Trophy className="w-3 h-3 text-amber-400" />
                    <span>Tụ {finalColumns.find((c) => c.isWinner).columnIndex + 1} Dẫn Đầu</span>
                  </div>
                )}
              </div>

              {/* Split Zoom Card & Quick Score Arena */}
              <div className="grid grid-cols-2 gap-3">
                {/* Left Sub-Box: Zoom of Last Dealt Card */}
                <div
                  onClick={() => lastDetectedCard?.image && setPreviewSnapshot(lastDetectedCard.image)}
                  className={`aspect-[4/3] bg-black rounded-xl border border-slate-800 overflow-hidden flex flex-col items-center justify-center relative ${
                    lastDetectedCard?.image ? 'cursor-pointer hover:border-amber-400' : ''
                  }`}
                >
                  {lastDetectedCard?.image ? (
                    <img
                      src={lastDetectedCard.image}
                      alt="Zoomed Card"
                      className="w-full h-full object-cover"
                    />
                  ) : (
                    <div className="text-center p-2">
                      <Camera className="w-6 h-6 mx-auto text-slate-600 mb-1" />
                      <span className="text-[10px] text-slate-500">Khung ảnh rút bài</span>
                    </div>
                  )}

                  {lastDetectedCard && (
                    <div className="absolute bottom-1 right-1 bg-black/80 px-1.5 py-0.5 rounded text-[10px] font-black text-amber-300">
                      {lastDetectedCard.raw}
                    </div>
                  )}
                </div>

                {/* Right Sub-Box: Quick Ranking Table */}
                <div className="space-y-1.5 text-xs">
                  {finalColumns.map((col) => (
                    <div
                      key={col.columnIndex}
                      className={`p-1.5 rounded-lg flex items-center justify-between border ${
                        col.isWinner
                          ? 'bg-amber-500/15 border-amber-400/50 text-amber-200 font-bold'
                          : 'bg-slate-950 border-slate-800/80 text-slate-400'
                      }`}
                    >
                      <span className="text-[11px] font-bold">Tụ {col.columnIndex + 1}</span>
                      <span
                        className={`text-[10px] font-black ${
                          col.isWinner ? 'text-amber-300' : 'text-slate-300'
                        }`}
                      >
                        {col.score.text}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
