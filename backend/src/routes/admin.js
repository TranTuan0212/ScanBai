const express = require('express');
const router = express.Router();
const bcrypt = require('bcryptjs');
const { PrismaClient } = require('@prisma/client');
const { authenticateToken } = require('../middleware/auth');
const { requireAdmin } = require('../middleware/admin');

const prisma = new PrismaClient();

// All admin routes require valid authentication & admin role
router.use(authenticateToken, requireAdmin);

/**
 * Helper to calculate expiredAt based on duration and unit
 */
function calculateExpirationDate(duration, unit, baseDate = new Date()) {
  const d = parseInt(duration, 10) || 1;
  const target = new Date(baseDate.getTime() < Date.now() ? Date.now() : baseDate.getTime());
  
  switch (unit) {
    case 'day':
      target.setDate(target.getDate() + d);
      break;
    case 'month':
      target.setMonth(target.getMonth() + d);
      break;
    case 'year':
      target.setFullYear(target.getFullYear() + d);
      break;
    default:
      target.setDate(target.getDate() + d);
  }
  return target;
}

/**
 * GET /api/admin/dashboard
 */
router.get('/dashboard', async (req, res) => {
  try {
    const totalUsers = await prisma.user.count();
    const activeLives = await prisma.session.count({
      where: { status: 'active' }
    });

    return res.status(200).json({
      totalUsers,
      activeLives
    });
  } catch (err) {
    console.error('[Admin Dashboard Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

/**
 * GET /api/admin/users
 */
router.get('/users', async (req, res) => {
  try {
    const users = await prisma.user.findMany({
      select: {
        id: true,
        email: true,
        role: true,
        expiredAt: true,
        createdAt: true
      },
      orderBy: { createdAt: 'desc' }
    });
    return res.status(200).json(users);
  } catch (err) {
    console.error('[Admin Get Users Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

/**
 * POST /api/admin/users
 * Body: { email, password, role, duration, durationUnit }
 */
router.post('/users', async (req, res) => {
  try {
    const { email, password, role = 'view', duration = 30, durationUnit = 'day' } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }

    const existingUser = await prisma.user.findUnique({
      where: { email: email.trim().toLowerCase() }
    });

    if (existingUser) {
      return res.status(409).json({ error: 'User with this email already exists' });
    }

    const hashedPassword = await bcrypt.hash(password, 10);
    const expiredAt = calculateExpirationDate(duration, durationUnit);

    const newUser = await prisma.user.create({
      data: {
        email: email.trim().toLowerCase(),
        password: hashedPassword,
        role: ['live', 'view', 'admin'].includes(role) ? role : 'view',
        expiredAt: expiredAt
      },
      select: {
        id: true,
        email: true,
        role: true,
        expiredAt: true,
        createdAt: true
      }
    });

    return res.status(201).json(newUser);
  } catch (err) {
    console.error('[Admin Create User Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

/**
 * DELETE /api/admin/users/:id
 */
router.delete('/users/:id', async (req, res) => {
  try {
    const { id } = req.params;

    // Check if user has an active session
    const activeSession = await prisma.session.findFirst({
      where: {
        userId: id,
        status: 'active'
      }
    });

    if (activeSession) {
      return res.status(409).json({
        error: 'Cannot delete user with an active live session',
        code: 'USER_HAS_ACTIVE_SESSION'
      });
    }

    // Delete associated sessions and then the user
    await prisma.$transaction([
      prisma.session.deleteMany({ where: { userId: id } }),
      prisma.user.delete({ where: { id } })
    ]);

    return res.status(200).json({ success: true, message: 'User deleted successfully' });
  } catch (err) {
    console.error('[Admin Delete User Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

/**
 * PUT /api/admin/users/:id/renew
 * Body: { duration, durationUnit }
 */
router.put('/users/:id/renew', async (req, res) => {
  try {
    const { id } = req.params;
    const { duration = 30, durationUnit = 'day' } = req.body;

    const user = await prisma.user.findUnique({
      where: { id }
    });

    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    const newExpiredAt = calculateExpirationDate(duration, durationUnit, new Date(user.expiredAt));

    const updatedUser = await prisma.user.update({
      where: { id },
      data: { expiredAt: newExpiredAt },
      select: {
        id: true,
        email: true,
        role: true,
        expiredAt: true
      }
    });

    return res.status(200).json(updatedUser);
  } catch (err) {
    console.error('[Admin Renew User Error]', err);
    return res.status(500).json({ error: 'Internal server error', message: err.message });
  }
});

module.exports = router;
