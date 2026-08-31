const express = require('express');
const router = express.Router();
const crypto = require('crypto');
const { PrismaClient } = require('@prisma/client');
const { authenticateToken } = require('../middleware/auth');
const { acquireLiveLock, renewLiveLock, releaseLiveLock, getLiveLockToken } = require('../redis/lock');
const { clearViewers } = require('../redis/viewers');
const { createInitialCardStack } = require('../utils/cardStack');

const prisma = new PrismaClient();

function parseStack(raw) {
  if (Array.isArray(raw)) return raw;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return [];
  }
}

/**
 * POST /api/sessions/start
 * Start a new live session with atomic Redis lock
 */
router.post('/start', authenticateToken, async (req, res) => {
  try {
    const userId = req.user.id;
    const deviceId = req.user.deviceId || 'unknown';
    const role = req.user.role;

    if (role === 'view') {
      return res.status(403).json({ error: 'View-only accounts cannot start live streams' });
    }

    let { rounds } = req.body;
    rounds = parseInt(rounds, 10);
    if (isNaN(rounds) || rounds < 2 || rounds > 9) {
      rounds = 3;
    }

    const sessionId = crypto.randomUUID();
    const lockToken = crypto.randomUUID();

    // 1. Try to acquire Atomic Live Lock in Redis
    const lockAcquired = await acquireLiveLock(userId, lockToken, 15);
    if (!lockAcquired) {
      return res.status(409).json({
        error: 'Active live session already exists on another device',
        code: 'LOCK_CONFLICT'
      });
    }

    // 2. Perform DB transaction
    try {
      const session = await prisma.$transaction(async (tx) => {
        // Clean up any stale active sessions for this user
        await tx.session.updateMany({
          where: {
            userId: userId,
            status: 'active'
          },
          data: {
            status: 'ended',
            endedAt: new Date()
          }
        });

        // Create new active session
        const initialStack = createInitialCardStack(rounds);
        return await tx.session.create({
          data: {
            id: sessionId,
            userId: userId,
            deviceId: deviceId,
            streamId: sessionId,
            lockToken: lockToken,
            rounds: rounds,
            cardStack: JSON.stringify(initialStack),
            cardCount: 0,
            status: 'active'
          }
        });
      });

      const antMediaWsUrl = process.env.ANT_MEDIA_WS_URL || 'ws://192.168.1.30:5080/WebRTCAppEE/websocket';

      return res.status(200).json({
        sessionId: session.id,
        streamId: session.streamId,
        antMediaWebSocketUrl: antMediaWsUrl,
        rounds: session.rounds,
        cardStack: parseStack(session.cardStack),
        cardCount: session.cardCount
      });
    } catch (dbError) {
      // Rollback Redis Lock if DB insertion failed
      await releaseLiveLock(userId, lockToken);
      console.error('[Session Start DB Error]', dbError);
      return res.status(409).json({ error: 'Failed to initialize session in database', details: dbError.message });
    }
  } catch (err) {
    console.error('[Session Start Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

/**
 * POST /api/sessions/heartbeat
 * Renew live session lock
 */
router.post('/heartbeat', authenticateToken, async (req, res) => {
  try {
    const { sessionId } = req.body;
    const userId = req.user.id;

    if (!sessionId) {
      return res.status(400).json({ error: 'sessionId is required' });
    }

    const session = await prisma.session.findFirst({
      where: {
        id: sessionId,
        userId: userId,
        status: 'active'
      }
    });

    if (!session) {
      return res.status(404).json({ error: 'Active session not found' });
    }

    // Check if account has expired
    if (new Date(req.user.expiredAt) <= new Date()) {
      // Gracefully terminate session
      await prisma.session.update({
        where: { id: session.id },
        data: { status: 'ended', endedAt: new Date() }
      });
      await releaseLiveLock(userId, session.lockToken);
      await clearViewers(sessionId);

      // Emit live_ended
      const io = req.app.get('io');
      if (io) {
        io.to(sessionId).emit('live_ended', sessionId);
      }

      return res.status(403).json({ error: 'Account expired during live session' });
    }

    // Renew Redis lock TTL to 15s
    const renewed = await renewLiveLock(userId, session.lockToken, 15);
    if (!renewed) {
      return res.status(409).json({ error: 'Lock lost or expired' });
    }

    return res.status(200).json({ success: true });
  } catch (err) {
    console.error('[Heartbeat Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

/**
 * DELETE /api/sessions/:sessionId
 * Graceful stop of a live session
 */
router.delete('/:sessionId', authenticateToken, async (req, res) => {
  try {
    const { sessionId } = req.params;
    const userId = req.user.id;

    const session = await prisma.session.findFirst({
      where: {
        id: sessionId,
        userId: userId,
        status: 'active'
      }
    });

    if (!session) {
      return res.status(404).json({ error: 'Active session not found or already ended' });
    }

    // 1. Update DB to ended
    await prisma.session.update({
      where: { id: sessionId },
      data: {
        status: 'ended',
        endedAt: new Date()
      }
    });

    // 2. Immediately release Redis lock
    await releaseLiveLock(userId, session.lockToken);

    // 3. Emit live_ended to Socket.IO room immediately
    const io = req.app.get('io');
    if (io) {
      io.to(sessionId).emit('live_ended', sessionId);
    }

    // 4. Clean up Redis Set viewers
    await clearViewers(sessionId);

    return res.status(200).json({ success: true, message: 'Session gracefully ended' });
  } catch (err) {
    console.error('[Session Delete Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

/**
 * GET /api/sessions/active
 * Get all currently active sessions for viewers to join
 */
router.get('/active', authenticateToken, async (req, res) => {
  try {
    const activeSessions = await prisma.session.findMany({
      where: {
        status: 'active'
      },
      include: {
        user: {
          select: {
            email: true,
            role: true
          }
        }
      },
      orderBy: {
        startedAt: 'desc'
      }
    });

    const antMediaWsUrl = process.env.ANT_MEDIA_WS_URL || 'ws://192.168.1.30:5080/WebRTCAppEE/websocket';

    const formatted = activeSessions.map((s) => ({
      sessionId: s.id,
      streamId: s.streamId,
      antMediaWebSocketUrl: antMediaWsUrl,
      deviceId: s.deviceId,
      startedAt: s.startedAt,
      rounds: s.rounds,
      cardStack: parseStack(s.cardStack),
      cardCount: s.cardCount,
      broadcasterEmail: s.user.email
    }));

    return res.status(200).json(formatted);
  } catch (err) {
    console.error('[Active Sessions Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

const multer = require('multer');
const path = require('path');
const { spawn } = require('child_process');
const fs = require('fs');

const uploadDir = path.join(__dirname, '../../../public/uploads/videos');
if (!fs.existsSync(uploadDir)) {
  fs.mkdirSync(uploadDir, { recursive: true });
}

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, uploadDir),
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname) || '.mp4';
    cb(null, `video_${Date.now()}_${Math.round(Math.random() * 1e4)}${ext}`);
  }
});
const upload = multer({ storage: storage });

/**
 * POST /api/sessions/upload-video-analysis
 * Server-side High-Speed Video Analysis Endpoint (< 10 seconds)
 */
router.post('/upload-video-analysis', upload.single('video'), (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'No video file provided' });
    }

    const videoPath = req.file.path;
    const totalHands = req.body.rounds || 3;
    const pythonScript = path.join(__dirname, '../../../server_video_analyzer.py');

    console.log(`[Server Video Analyzer] Running analysis on: ${videoPath} (${totalHands} hands)`);

    const pythonProcess = spawn('python', [pythonScript, videoPath, String(totalHands)]);
    let stdoutData = '';
    let stderrData = '';

    pythonProcess.stdout.on('data', (data) => {
      stdoutData += data.toString();
    });

    pythonProcess.stderr.on('data', (data) => {
      stderrData += data.toString();
    });

    pythonProcess.on('close', (code) => {
      fs.unlink(videoPath, () => {});

      if (code !== 0) {
        console.error('[Server Video Analyzer Error]', stderrData);
        return res.status(500).json({ error: 'Python analyzer failed', details: stderrData });
      }

      try {
        const result = JSON.parse(stdoutData.trim());
        const io = req.app.get('io');
        if (io) {
          io.emit('video_analysis_complete', result);
        }
        return res.status(200).json(result);
      } catch (parseErr) {
        console.error('[Server Video Analyzer JSON Parse Error]', stdoutData);
        return res.status(500).json({ error: 'Invalid JSON from analyzer', raw: stdoutData });
      }
    });
  } catch (err) {
    console.error('[Upload Video Analysis Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

module.exports = router;
