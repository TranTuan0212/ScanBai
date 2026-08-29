const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { PrismaClient } = require('@prisma/client');
const { authenticateToken, JWT_SECRET } = require('../middleware/auth');

const prisma = new PrismaClient();
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '7d';

/**
 * POST /api/auth/login
 * Body: { email, password, deviceId }
 */
router.post('/login', async (req, res) => {
  try {
    const { email, password, deviceId } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }

    const user = await prisma.user.findUnique({
      where: { email: email.trim().toLowerCase() }
    });

    if (!user) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const isPasswordValid = await bcrypt.compare(password, user.password);
    if (!isPasswordValid) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    // Check account expiration
    if (new Date(user.expiredAt) <= new Date()) {
      return res.status(403).json({
        error: 'Account has expired',
        expiredAt: user.expiredAt
      });
    }

    const token = jwt.sign(
      {
        userId: user.id,
        role: user.role,
        deviceId: deviceId || 'unknown'
      },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRES_IN }
    );

    return res.status(200).json({
      user: {
        id: user.id,
        email: user.email,
        role: user.role,
        expiredAt: user.expiredAt
      },
      token
    });
  } catch (err) {
    console.error('[Auth Route Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

/**
 * GET /api/users/me
 * Headers: Authorization: Bearer <token>
 */
router.get('/me', authenticateToken, async (req, res) => {
  return res.status(200).json({
    id: req.user.id,
    email: req.user.email,
    role: req.user.role,
    expiredAt: req.user.expiredAt
  });
});

module.exports = router;
