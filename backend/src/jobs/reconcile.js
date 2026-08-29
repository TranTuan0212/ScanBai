const { PrismaClient } = require('@prisma/client');
const { getLiveLockToken } = require('../redis/lock');
const { clearViewers } = require('../redis/viewers');

const prisma = new PrismaClient();

/**
 * Reconcile active sessions: End any session whose Redis lock has expired or token mismatched
 * @param {import('socket.io').Server} io 
 */
async function reconcileActiveSessions(io) {
  try {
    const activeSessions = await prisma.session.findMany({
      where: { status: 'active' }
    });

    for (const session of activeSessions) {
      const activeLockToken = await getLiveLockToken(session.userId);

      // If Redis key missing or lockToken doesn't match, session is orphaned
      if (!activeLockToken || activeLockToken !== session.lockToken) {
        console.log(`[Reconcile Job] Ending orphaned session: ${session.id} (userId: ${session.userId})`);

        await prisma.session.update({
          where: { id: session.id },
          data: {
            status: 'ended',
            endedAt: new Date()
          }
        });

        await clearViewers(session.id);

        if (io) {
          io.to(session.id).emit('live_ended', session.id);
        }
      }
    }
  } catch (err) {
    console.error('[Reconcile Job Error]', err.message);
  }
}

/**
 * Start periodic reconciliation timer
 * @param {import('socket.io').Server} io 
 * @param {number} intervalMs 
 */
function startReconciliationJob(io, intervalMs = 30000) {
  const timer = setInterval(() => {
    reconcileActiveSessions(io);
  }, intervalMs);

  console.log(`[Reconcile Job] Scheduled to run every ${intervalMs / 1000}s`);
  return timer;
}

module.exports = {
  reconcileActiveSessions,
  startReconciliationJob
};
