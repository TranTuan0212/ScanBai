require('dotenv').config();
const http = require('http');
const express = require('express');
const cors = require('cors');
const { Server } = require('socket.io');

const authRoutes = require('./src/routes/auth');
const sessionRoutes = require('./src/routes/sessions');
const adminRoutes = require('./src/routes/admin');
const { setupWebSocket } = require('./src/websocket');
const { startReconciliationJob } = require('./src/jobs/reconcile');
const { startUdpDiscovery, getLocalIpAddress } = require('./src/utils/udpDiscovery');

const app = express();
const server = http.createServer(app);

const PORT = parseInt(process.env.PORT, 10) || 3000;
const HOST = process.env.HOST || '0.0.0.0';

// Global CORS & JSON parser
app.use(cors({ origin: '*' }));
app.use(express.json());

// Initialize Socket.IO with CORS enabled for LAN & Web
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});

// Provide io instance to express app
app.set('io', io);

// Health check endpoint
app.get('/api/health', (req, res) => {
  res.status(200).json({ status: 'ok', timestamp: new Date().toISOString(), ip: getLocalIpAddress() });
});

const path = require('path');

// Mount API routes
app.use('/api/auth', authRoutes);
app.use('/api/sessions', sessionRoutes);
app.use('/api/admin', adminRoutes);

// Serve Web Video Tester page for direct laptop testing
app.get('/test', (req, res) => {
  res.sendFile(path.join(__dirname, 'public/video_test.html'));
});

// Serve Admin Dashboard Static Frontend Files
const adminDistPath = path.join(__dirname, '../admin-dashboard/dist');
app.use(express.static(adminDistPath));

// SPA Fallback for Admin Dashboard routing
app.get('*', (req, res, next) => {
  if (req.path.startsWith('/api')) return next();
  res.sendFile(path.join(adminDistPath, 'index.html'), (err) => {
    if (err) next();
  });
});

// Setup Socket.IO logic
setupWebSocket(io);

// Start background reconciliation cron
startReconciliationJob(io, 30000);

// Start UDP Auto-Discovery beacon for Android clients on the same Wi-Fi
startUdpDiscovery(3001, PORT);

// Global Error Handler
app.use((err, req, res, next) => {
  console.error('[Unhandled Server Error]', err);
  res.status(500).json({ error: 'Internal Server Error', message: err.message });
});

// Start listening
server.listen(PORT, HOST, () => {
  const localIp = getLocalIpAddress();
  console.log(`[CardLink Backend] Server running on http://${HOST}:${PORT} (Local Wi-Fi IP: http://${localIp}:${PORT})`);
  console.log(`[CardLink Backend] Ready for Android Live/Viewer and Admin Dashboard`);
});

module.exports = { app, server, io };
