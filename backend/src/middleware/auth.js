const jwt = require('jsonwebtoken');
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

const JWT_SECRET = process.env.JWT_SECRET || 'cardlink-secret-key-super-secure-2026';

/**
 * Authentication middleware for REST API
 */
async function authenticateToken(req, res, next) {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];

  if (!token) {
    return res.status(401).json({ error: 'Missing authorization token' });
  }

  try {
    const decoded = jwt.verify(token, JWT_SECRET);

    // Check token expiration timestamp
    if (decoded.exp && decoded.exp * 1000 <= Date.now()) {
      return res.status(403).json({ error: 'Token expired' });
    }

    // Check user account existence and validity in database
    const user = await prisma.user.findUnique({
      where: { id: decoded.userId }
    });

    if (!user) {
      return res.status(401).json({ error: 'User not found' });
    }

    // Check account expiration date
    if (new Date(user.expiredAt) <= new Date()) {
      return res.status(403).json({ 
        error: 'Account expired',
        expiredAt: user.expiredAt 
      });
    }

    req.user = {
      id: user.id,
      email: user.email,
      role: user.role,
      expiredAt: user.expiredAt,
      deviceId: decoded.deviceId
    };

    next();
  } catch (err) {
    return res.status(401).json({ error: 'Invalid or expired token', message: err.message });
  }
}

module.exports = {
  authenticateToken,
  JWT_SECRET
};
