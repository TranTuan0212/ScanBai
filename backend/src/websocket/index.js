const jwt = require('jsonwebtoken');
const { PrismaClient } = require('@prisma/client');
const { getLiveLockToken } = require('../redis/lock');
const { withSessionMutex } = require('../redis/mutex');
const { addViewer, removeViewer, getViewerCount } = require('../redis/viewers');
const { appendCardToStack, createInitialCardStack } = require('../utils/cardStack');
const { enhanceCardImage } = require('../utils/imageEnhancer');

const prisma = new PrismaClient();
const JWT_SECRET = process.env.JWT_SECRET || 'cardlink-secret-key-super-secure-2026';

function parseStack(raw) {
  if (Array.isArray(raw)) return raw;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return [];
  }
}

function setupWebSocket(io) {
  // Authentication middleware with Public Viewer Fallback
  io.use(async (socket, next) => {
    try {
      const token = socket.handshake.auth?.token || socket.handshake.query?.token;
      if (token) {
        try {
          const decoded = jwt.verify(token, JWT_SECRET);
          socket.userId = decoded.userId || 'guest';
          socket.userRole = decoded.role || 'view';
          socket.deviceId = decoded.deviceId || 'unknown';
          return next();
        } catch (_) {}
      }
      
      // Allow Public Viewer access so dashboard live stream always loads
      socket.userId = 'guest_' + socket.id;
      socket.userRole = 'view';
      socket.deviceId = 'viewer_' + socket.id;
      next();
    } catch (err) {
      socket.userId = 'guest_' + socket.id;
      socket.userRole = 'view';
      socket.deviceId = 'viewer_' + socket.id;
      next();
    }
  });

  io.on('connection', (socket) => {
    console.log(`[Socket.IO] Client connected: socketId=${socket.id}, userId=${socket.userId}, deviceId=${socket.deviceId}`);

    // Event: join_room
    socket.on('join_room', async (data) => {
      try {
        const sessionId = typeof data === 'object' ? data.sessionId : data;
        if (!sessionId) return;

        socket.join(sessionId);
        socket.currentSessionId = sessionId;

        const session = await prisma.session.findUnique({
          where: { id: sessionId }
        });

        if (session) {
          const currentRedisLock = await getLiveLockToken(session.userId);
          const isOwner = (currentRedisLock === session.lockToken) &&
                          (socket.userId === session.userId);

          socket.isBroadcaster = isOwner;

          if (!isOwner) {
            await addViewer(sessionId, socket.deviceId);
          }

          const viewerCount = await getViewerCount(sessionId, session.deviceId);
          io.to(sessionId).emit('viewer_count', viewerCount);
          socket.emit('card_state', parseStack(session.cardStack));
        }
      } catch (err) {
        console.error('[Socket.IO join_room Error]', err);
      }
    });

    // Event: card_detected
    socket.on('card_detected', async (data) => {
      try {
        const { sessionId, label, imageBase64 } = data || {};
        if (!label) return;

        const targetSessionId = sessionId || socket.currentSessionId || 'active_live_stream';
        const cardItem = {
          label: label,
          image: imageBase64 ? (imageBase64.startsWith('data:') ? imageBase64 : `data:image/jpeg;base64,${imageBase64}`) : null,
          timestamp: new Date().toISOString()
        };

        // Broadcast card_detected event to all connected web clients & rooms
        io.to(targetSessionId).emit('card_detected', cardItem);
        io.emit('card_detected', cardItem);

        // Save to active session cardStack in DB and broadcast card_state
        if (targetSessionId) {
          try {
            const session = await prisma.session.findUnique({ where: { id: targetSessionId } });
            if (session) {
              const currentStack = parseStack(session.cardStack);
              const nextStack = [...currentStack];
              if (nextStack.length === 0) nextStack.push([]);
              const currentCol = nextStack[nextStack.length - 1];
              if (currentCol.length >= 3) {
                nextStack.push([cardItem]);
              } else {
                currentCol.push(cardItem);
              }
              await prisma.session.update({
                where: { id: targetSessionId },
                data: { cardStack: JSON.stringify(nextStack) }
              });
              io.to(targetSessionId).emit('card_state', nextStack);
              io.emit('card_state', nextStack);
            }
          } catch (_) {}
        }
      } catch (err) {
        console.error('[Socket.IO card_detected Error]', err);
      }
    });

    // Event: live_frame (Real-time live video preview stream)
    socket.on('live_frame', (data) => {
      try {
        const sessionId = data?.sessionId || socket.currentSessionId;
        const frame = data?.frame || data?.dataUri || data?.imageBase64;
        if (frame) {
          if (sessionId) {
            io.to(sessionId).emit('live_frame', frame);
          }
          io.emit('live_frame', frame);
        }
      } catch (err) {
        console.error('[Socket.IO live_frame Error]', err);
      }
    });

    // Event: disconnect
    socket.on('disconnect', async () => {
      if (socket.currentSessionId && socket.deviceId) {
        await removeViewer(socket.currentSessionId, socket.deviceId);
        const count = await getViewerCount(socket.currentSessionId);
        io.to(socket.currentSessionId).emit('viewer_count', count);
      }
      console.log(`[Socket.IO] Client disconnected: socketId=${socket.id}`);
    });
  });
}

module.exports = { setupWebSocket };
